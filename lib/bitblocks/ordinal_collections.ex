defmodule Bitblocks.OrdinalCollections do
  @moduledoc """
  1Sat ordinal collections (#30), Grand Tardinians first.

  **Membership is proven, not claimed.** Any inscription can name a
  `collectionId` in its MAP, so the MAP alone would admit fakes. Bubblemint
  mints spend the collection's mint contract in a chain: the first mint spends
  the collection outpoint, and each mint's output 0 carries the contract to the
  next. A tx is a mint only if it spends a link of that chain *and* inscribes a
  `collectionItem` naming this collection; its output 0 then joins the chain.

  **Discovery** takes a hint list of mint txids (GorillaPool's search, via
  `Release.sync_ordinal_collection/1`), imports them, walks the chain locally,
  and follows past the hint's end with WhatsOnChain's `/spent`, so an item the
  hint missed is still found and a fake in the hint is rejected.

  **Ownership** follows each item's sat from its origin through spends
  (`trace/1`). A 1Sat sat in input `i` sits at the offset equal to the value of
  inputs `0..i-1`, and lands in the output whose range covers that offset. If
  that output isn't 1 sat, the trail is `unknown` rather than guessed.

  Transactions come from our own index first and WhatsOnChain second
  (`Bitblocks.Woc`); every imported body is checked against its txid.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawTx, Transaction, TxIngest}
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Ordinals.Inscription
  alias Bitblocks.{Repo, Woc}

  @collections %{
    "grand-tardinians" => "f099182e168c0a30a9f97556d156c8b6284cfc3f76eca8352807b1ceff29da04_0"
  }

  @max_hops 30

  @doc "Known collections: slug => collection id (origin outpoint)."
  def known, do: @collections

  @doc """
  Resolves a slug, or a collection id (origin outpoint) that is known or has
  indexed items, to the collection id; nil otherwise.
  """
  def resolve(slug_or_id) when is_binary(slug_or_id) do
    cond do
      id = @collections[slug_or_id] -> id
      slug_or_id in Map.values(@collections) -> slug_or_id
      slug_or_id =~ ~r/\A[0-9a-f]{64}_\d+\z/ and indexed?(slug_or_id) -> slug_or_id
      true -> nil
    end
  end

  defp indexed?(cid), do: Repo.exists?(from i in Item, where: i.collection_id == ^cid)

  # -- Import ------------------------------------------------------------------

  @doc """
  Stores the given txids that we don't have yet, fetched from WhatsOnChain in
  bulk. Returns `%{stored, existing, failed}` (failed lists `{txid, reason}`).
  """
  @spec import_txs([String.t()]) :: %{
          stored: non_neg_integer(),
          existing: non_neg_integer(),
          failed: list()
        }
  def import_txs(txids) do
    txids = Enum.uniq(txids)
    have = stored_txids(txids)
    missing = Enum.reject(txids, &MapSet.member?(have, &1))

    missing
    |> Enum.chunk_every(Woc.bulk_size())
    |> Enum.reduce(%{stored: 0, existing: MapSet.size(have), failed: []}, fn batch, acc ->
      case Woc.txs(batch) do
        {:ok, txs} ->
          returned = MapSet.new(txs, & &1["txid"])
          absent = for t <- batch, not MapSet.member?(returned, t), do: {t, :not_returned}

          Enum.reduce(txs, %{acc | failed: absent ++ acc.failed}, fn tx, acc ->
            case TxIngest.store(tx, %Block{hash: tx["blockhash"], height: tx["blockheight"]}) do
              :ok -> %{acc | stored: acc.stored + 1}
              {:error, reason} -> %{acc | failed: [{tx["txid"], reason} | acc.failed]}
            end
          end)

        {:error, reason} ->
          %{acc | failed: Enum.map(batch, &{&1, reason}) ++ acc.failed}
      end
    end)
  end

  defp stored_txids(txids) do
    from(t in Transaction, where: t.txid in ^txids and not is_nil(t.raw), select: t.txid)
    |> Repo.all()
    |> MapSet.new()
  end

  # -- Discovery and membership --------------------------------------------------

  @doc """
  Imports the collection's mints and indexes their items.

  `hint_txids` are candidate mint txids (from any indexer); they are only
  candidates. Options: `follow: false` skips following the chain past the
  hint with WhatsOnChain.

  Returns `%{mints, items, rejected, import}`: `rejected` counts hinted txs
  that are not on the mint chain.
  """
  def sync(collection_id, hint_txids, opts \\ []) do
    [collection_txid, _] = String.split(collection_id, "_")
    import = import_txs([collection_txid | hint_txids])

    spenders = spender_index(hint_txids)
    mints = walk_chain(collection_id, spenders, Keyword.get(opts, :follow, true))

    items =
      mints
      |> Enum.map(fn {txid, tx, height} -> index_items(collection_id, txid, tx, height) end)
      |> Enum.sum()

    mint_ids = MapSet.new(mints, &elem(&1, 0))
    rejected = hint_txids |> Enum.uniq() |> Enum.count(&(not MapSet.member?(mint_ids, &1)))

    Logger.info(
      "OrdinalCollections.sync #{collection_id}: #{length(mints)} mints, #{items} items, " <>
        "#{rejected} hinted txs rejected"
    )

    %{mints: length(mints), items: items, rejected: rejected, import: import}
  end

  # outpoint ("txid_vout") => spending txid, over the candidate txs we hold.
  defp spender_index(txids) do
    for txid <- Enum.uniq(txids),
        {:ok, tx, _height} <- [load_tx(txid)],
        input <- tx.inputs,
        into: %{} do
      {outpoint_id(input.outpoint), txid}
    end
  end

  # Breadth-first from the collection outpoint: each chain link is spent by at
  # most one tx; it is a mint if it also inscribes an item of this collection.
  defp walk_chain(collection_id, spenders, follow?) do
    do_walk([collection_id], spenders, follow?, collection_id, MapSet.new(), [])
  end

  defp do_walk([], _spenders, _follow?, _cid, _seen, mints), do: Enum.reverse(mints)

  defp do_walk([link | queue], spenders, follow?, cid, seen, mints) do
    with spender when is_binary(spender) <- spenders[link] || follow_spend(link, follow?),
         false <- MapSet.member?(seen, spender),
         {:ok, tx, height} <- load_tx(spender),
         true <- spends?(tx, link) and claims_items?(tx, cid) do
      do_walk(
        queue ++ ["#{spender}_0"],
        spenders,
        follow?,
        cid,
        MapSet.put(seen, spender),
        [{spender, tx, height} | mints]
      )
    else
      _ -> do_walk(queue, spenders, follow?, cid, seen, mints)
    end
  end

  defp follow_spend(_link, false), do: nil

  defp follow_spend(link, true) do
    [txid, vout] = String.split(link, "_")

    case Woc.spent(txid, String.to_integer(vout)) do
      {:ok, %{txid: spender}} ->
        import_txs([spender])
        spender

      _ ->
        nil
    end
  end

  defp spends?(tx, link), do: Enum.any?(tx.inputs, &(outpoint_id(&1.outpoint) == link))

  defp claims_items?(tx, cid), do: tx |> items_in(cid) |> Enum.any?()

  defp items_in(%BSV.Tx{outputs: outputs}, cid) do
    for {out, vout} <- Enum.with_index(outputs),
        out.satoshis == 1,
        {:ok, insc} <- [Inscription.parse(out.script)],
        insc.map["subType"] == "collectionItem",
        is_map(insc.map["subTypeData"]),
        insc.map["subTypeData"]["collectionId"] == cid,
        do: {vout, insc}
  end

  defp index_items(cid, txid, tx, height) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for {vout, insc} <- items_in(tx, cid) do
        origin = "#{txid}_#{vout}"

        %{
          collection_id: cid,
          origin: origin,
          mint_txid: txid,
          mint_height: height,
          name: insc.map["name"],
          content_type: insc.content_type,
          traits: traits(insc.map["subTypeData"]),
          current_outpoint: origin,
          owner: insc.owner,
          trace_state: "untraced",
          inserted_at: now,
          updated_at: now
        }
      end

    # Re-sync refreshes metadata but keeps ownership traced so far.
    {count, _} =
      Repo.insert_all(Item, rows,
        on_conflict: {:replace, [:name, :content_type, :traits, :mint_height, :updated_at]},
        conflict_target: [:collection_id, :origin]
      )

    count
  end

  defp traits(%{"attributes" => attrs}) when is_list(attrs) do
    for %{"name" => name} = attr <- attrs do
      details = attr["details"] || %{}
      %{"name" => name, "value" => details["name"], "description" => details["description"]}
    end
  end

  defp traits(_), do: []

  # -- Ownership -----------------------------------------------------------------

  @doc """
  Follows `item`'s sat from where we last saw it (its origin, if never traced)
  to where it sits now, and records the owner. Returns the updated item.
  """
  @spec trace(Item.t()) :: {:ok, Item.t()}
  def trace(%Item{} = item) do
    start = if item.trace_state == "current", do: item.current_outpoint, else: item.origin
    {state, outpoint, owner, reason} = follow(start, 0)

    item
    |> Ecto.Changeset.change(%{
      trace_state: state,
      current_outpoint: outpoint,
      owner: owner,
      trace_reason: reason,
      trace_source: "whatsonchain",
      traced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc "Traces every item of a collection. Returns counts by trace_state."
  def trace_all(collection_id) do
    from(i in Item, where: i.collection_id == ^collection_id, order_by: i.id)
    |> Repo.all()
    |> Enum.map(fn item ->
      {:ok, traced} = trace(item)
      traced.trace_state
    end)
    |> Enum.frequencies()
  end

  defp follow(outpoint, hops) when hops >= @max_hops,
    do: {"unknown", outpoint, nil, "more than #{@max_hops} transfers; stopped"}

  defp follow(outpoint, hops) do
    [txid, vout] = String.split(outpoint, "_")

    case Woc.spent(txid, String.to_integer(vout)) do
      {:ok, :unspent} ->
        {"current", outpoint, owner_at(outpoint), nil}

      {:ok, %{txid: spender, vin: vin}} ->
        import_txs([spender])

        case landing(spender, vin) do
          {:ok, next} -> follow(next, hops + 1)
          {:unknown, reason} -> {"unknown", outpoint, nil, reason}
        end

      {:error, reason} ->
        {"unknown", outpoint, nil, "whatsonchain: #{inspect(reason)}"}
    end
  end

  # The outpoint where a 1-sat input at `vin` of `spender` lands.
  defp landing(spender, vin) do
    with {:ok, tx, _} <- load_tx(spender),
         {:ok, offset} <- input_offset(tx, vin) do
      tx.outputs
      |> Enum.with_index()
      |> Enum.reduce_while(0, fn {out, k}, start ->
        if offset < start + out.satoshis,
          do: {:halt, {k, out.satoshis}},
          else: {:cont, start + out.satoshis}
      end)
      |> case do
        {k, 1} -> {:ok, "#{spender}_#{k}"}
        {_k, sats} when is_integer(sats) -> {:unknown, "sat moved into a #{sats}-sat output"}
        _ -> {:unknown, "sat went to fees"}
      end
    else
      _ -> {:unknown, "spending tx #{spender} unavailable"}
    end
  end

  defp input_offset(tx, vin) do
    prior = Enum.take(tx.inputs, vin)
    import_txs(Enum.map(prior, &BSV.OutPoint.get_txid(&1.outpoint)))

    Enum.reduce_while(prior, {:ok, 0}, fn input, {:ok, sum} ->
      case output_value(input.outpoint) do
        {:ok, sats} -> {:cont, {:ok, sum + sats}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp output_value(%BSV.OutPoint{vout: vout} = op) do
    with {:ok, tx, _} <- load_tx(BSV.OutPoint.get_txid(op)),
         %BSV.TxOut{satoshis: sats} <- Enum.at(tx.outputs, vout) do
      {:ok, sats}
    else
      _ -> :error
    end
  end

  defp owner_at(outpoint) do
    [txid, vout] = String.split(outpoint, "_")

    with {:ok, tx, _} <- load_tx(txid),
         %BSV.TxOut{script: script} <- Enum.at(tx.outputs, String.to_integer(vout)) do
      Inscription.lock_owner(script)
    else
      _ -> nil
    end
  end

  # -- Reads ---------------------------------------------------------------------

  @doc "A page of items in mint order. Options: `:cursor` (an item id), `:limit`."
  def list_items(collection_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(500) |> max(1)

    query =
      from(i in Item,
        where: i.collection_id == ^collection_id,
        order_by: [asc: i.id],
        limit: ^(limit + 1)
      )

    query =
      case opts[:cursor] do
        nil -> query
        cursor -> where(query, [i], i.id > ^cursor)
      end

    {items, rest} = query |> Repo.all() |> Enum.split(limit)
    next = if rest != [], do: List.last(items).id
    %{items: items, next_cursor: next}
  end

  @doc "The item at `outpoint`: by its origin or where it sits now."
  def get_item(collection_id, outpoint) do
    Repo.one(
      from i in Item,
        where:
          i.collection_id == ^collection_id and
            (i.origin == ^outpoint or i.current_outpoint == ^outpoint),
        limit: 1
    )
  end

  @doc "Counts for a collection: items, and items by trace_state."
  def summary(collection_id) do
    states =
      from(i in Item,
        where: i.collection_id == ^collection_id,
        group_by: i.trace_state,
        select: {i.trace_state, count()}
      )
      |> Repo.all()
      |> Map.new()

    %{items: states |> Map.values() |> Enum.sum(), trace_states: states}
  end

  # -- Helpers -------------------------------------------------------------------

  defp load_tx(txid) do
    with %{raw: raw, block_height: height} when is_binary(raw) <-
           Repo.one(
             from t in Transaction, where: t.txid == ^txid, select: map(t, [:raw, :block_height])
           ),
         {:ok, tx} <- RawTx.parse(raw) do
      {:ok, tx, height}
    else
      _ -> :error
    end
  end

  defp outpoint_id(%BSV.OutPoint{vout: vout} = op), do: "#{BSV.OutPoint.get_txid(op)}_#{vout}"
end
