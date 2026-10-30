defmodule Bitblocks.OrdinalCollections do
  @moduledoc """
  NFT collections with proven membership and traced ownership (#30): Grand
  Tardinians (1Sat, `OneSat`) and Rexxies (Run, `RunJig`).

  **Membership is proven, not claimed.** Both kinds mint through a chain: each
  mint spends the collection's current link (Bubblemint's mint contract, or a
  Run class jig) and carries it on. The engine walks that chain from the
  collection's first link; the protocol decides from the bytes whether a tx
  mints and where the chain goes next. A copycat that claims the collection
  (a MAP `collectionId`, a look-alike name) can't spend the chain.

  **Discovery** takes a hint list of mint txids (GorillaPool's search, or a
  catalog; see `Release.sync_ordinal_collection/1`), imports them, walks the
  chain locally, and follows past the hint's end with WhatsOnChain's
  `/spent`, so an item the hint missed is still found and a fake in the hint
  is rejected.

  **Ownership** follows each item from its origin through spends (`trace/1`);
  the protocol says where a spent item lands (a 1Sat sat by input offset, a
  Run jig by the payload's output order). What it can't decide from the bytes
  is `unknown`, never guessed.

  Transactions come from our own index first and WhatsOnChain second
  (`Bitblocks.Woc`); every imported body is checked against its txid.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawTx, Transaction, TxIngest}
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.{Repo, Woc}

  # id: the chain's first link (the collection's origin outpoint).
  # hint: where candidate mint txids come from (only candidates; see sync/3).
  @collections %{
    "grand-tardinians" => %{
      id: "f099182e168c0a30a9f97556d156c8b6284cfc3f76eca8352807b1ceff29da04_0",
      protocol: Bitblocks.OrdinalCollections.OneSat,
      hint: :gorillapool
    },
    "rexxies" => %{
      # The Rexxie COL class (`…_o2` in Run notation).
      id: "12d8ca4bc0eaf26660627cc1671de6a0047246f39f3aa06633f8204223d70cc5_2",
      protocol: Bitblocks.OrdinalCollections.RunJig,
      catalog: Bitblocks.Rexxies.Catalog,
      hint: :catalog
    }
  }

  # Per trace. A longer trail stops as "partial" and the next trace resumes.
  @max_hops 100

  @doc "Transfers followed per trace before stopping as `partial`."
  def max_hops, do: @max_hops

  @doc "Known collections: slug => collection id (origin outpoint)."
  def known, do: Map.new(@collections, fn {slug, config} -> {slug, config.id} end)

  @doc """
  The config for a collection id: a known collection's, or 1Sat rules for any
  other collection origin outpoint.
  """
  def config_for(cid) do
    Enum.find_value(@collections, %{id: cid, protocol: Bitblocks.OrdinalCollections.OneSat}, fn
      {_slug, %{id: ^cid} = config} -> config
      _ -> nil
    end)
  end

  @doc """
  Resolves a slug, or a collection id (origin outpoint) that is known or has
  indexed items, to the collection id; nil otherwise.
  """
  def resolve(slug_or_id) when is_binary(slug_or_id) do
    known = known()

    cond do
      id = known[slug_or_id] -> id
      slug_or_id in Map.values(known) -> slug_or_id
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
    |> tap(fn _ -> keep_blobs(txids) end)
  end

  # Every tx a collection touches is kept in the blob store (mints, transfers,
  # inputs used for sat offsets). Silent when the store isn't configured: this
  # runs on every trace hop, and Release.store_collection_blobs/1 reports the
  # store's state once, explicitly.
  defp keep_blobs([]), do: :ok

  defp keep_blobs(txids) do
    if Bitblocks.TxStore.ready?() == :ok, do: Bitblocks.TxStore.enqueue(txids)
    :ok
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
    config = config_for(collection_id)
    mints = walk_chain(config, spenders, Keyword.get(opts, :follow, true))

    items =
      mints
      |> Enum.map(fn {txid, height, items} -> index_items(collection_id, txid, height, items) end)
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
  # most one tx, and the protocol decides whether that tx mints and where the
  # chain goes next. Txs that carry the chain on without minting are walked
  # through but aren't mints.
  defp walk_chain(config, spenders, follow?) do
    do_walk([config.id], spenders, follow?, config, MapSet.new(), [])
  end

  defp do_walk([], _spenders, _follow?, _config, _seen, mints), do: Enum.reverse(mints)

  defp do_walk([link | queue], spenders, follow?, config, seen, mints) do
    with spender when is_binary(spender) <- spenders[link] || follow_spend(link, follow?),
         false <- MapSet.member?(seen, spender),
         {:ok, tx, height} <- load_tx(spender),
         {:ok, items, next_links} <- config.protocol.mint(tx, spender, link, config) do
      mints = if items == [], do: mints, else: [{spender, height, items} | mints]
      do_walk(queue ++ next_links, spenders, follow?, config, MapSet.put(seen, spender), mints)
    else
      _ -> do_walk(queue, spenders, follow?, config, seen, mints)
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

  defp index_items(cid, txid, height, items) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for item <- items do
        origin = "#{txid}_#{item.vout}"

        %{
          collection_id: cid,
          origin: origin,
          mint_txid: txid,
          mint_height: height,
          name: item[:name],
          content_type: item[:content_type],
          traits: item[:traits] || [],
          current_outpoint: origin,
          owner: item[:owner],
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

  # -- Ownership -----------------------------------------------------------------

  @doc """
  Follows `item`'s sat from where we last saw it (its origin, if never traced)
  to where it sits now, and records the owner. Returns the updated item.
  """
  @spec trace(Item.t(), keyword()) :: {:ok, Item.t()}
  def trace(%Item{} = item, opts \\ []) do
    # current: re-check from where it sat; partial: resume where the last trace
    # stopped; otherwise (or with from: :origin) start from the origin, which
    # rebuilds the trail.
    resume? =
      Keyword.get(opts, :from) != :origin and item.trace_state in ["current", "partial"] and
        item.current_outpoint != nil

    start = if resume?, do: item.current_outpoint, else: item.origin
    protocol = config_for(item.collection_id).protocol
    {{state, outpoint, owner, reason}, steps} = follow(start, 0, protocol)
    trail = if resume?, do: Enum.uniq((item.trail || []) ++ steps), else: steps

    item
    |> Ecto.Changeset.change(%{
      trace_state: state,
      current_outpoint: outpoint,
      owner: owner,
      trail: trail,
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

  # Returns {{state, outpoint, owner, reason}, trail}: trail is the txids the
  # item moved through on this walk, oldest first (a spend that destroys the
  # item is included, as the last step of its history).
  defp follow(outpoint, hops, protocol, trail \\ [])

  defp follow(outpoint, hops, _protocol, trail) when hops >= @max_hops,
    do:
      {{"partial", outpoint, nil,
        "stopped after #{@max_hops} transfers; the next trace continues from here"},
       Enum.reverse(trail)}

  defp follow(outpoint, hops, protocol, trail) do
    [txid, vout] = String.split(outpoint, "_")

    case Woc.spent(txid, String.to_integer(vout)) do
      {:ok, :unspent} ->
        result =
          case owner_at(outpoint, protocol) do
            nil ->
              {"current", outpoint, nil, "held by a non-P2PKH lock (e.g. a marketplace listing)"}

            owner ->
              {"current", outpoint, owner, nil}
          end

        {result, Enum.reverse(trail)}

      {:ok, %{txid: spender, vin: vin}} ->
        import_txs([spender])
        trail = [spender | trail]

        with {:ok, tx, _} <- load_tx(spender),
             {:ok, next} <- protocol.landing(tx, spender, vin, &output_value/1) do
          follow(next, hops + 1, protocol, trail)
        else
          {:unknown, reason} ->
            {{"unknown", outpoint, nil, reason}, Enum.reverse(trail)}

          _ ->
            {{"unknown", outpoint, nil, "spending tx #{spender} unavailable"},
             Enum.reverse(trail)}
        end

      {:error, reason} ->
        {{"unknown", outpoint, nil, "whatsonchain: #{inspect(reason)}"}, Enum.reverse(trail)}
    end
  end

  # Value of an outpoint, importing its tx if we don't hold it.
  defp output_value(%BSV.OutPoint{vout: vout} = op) do
    txid = BSV.OutPoint.get_txid(op)
    import_txs([txid])

    with {:ok, tx, _} <- load_tx(txid),
         %BSV.TxOut{satoshis: sats} <- Enum.at(tx.outputs, vout) do
      {:ok, sats}
    else
      _ -> :error
    end
  end

  defp owner_at(outpoint, protocol) do
    [txid, vout] = String.split(outpoint, "_")

    with {:ok, tx, _} <- load_tx(txid),
         %BSV.TxOut{} = out <- Enum.at(tx.outputs, String.to_integer(vout)) do
      protocol.owner(out)
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

  @doc """
  The service's explicit membership claim for a collection, so a reader can
  name it and pin it: who verified, on what basis, the hash of the verified
  origin list (sha256 of the origins, sorted, newline-joined), and the highest
  mint height it covers. The MAP `collectionId` on each item is the chain's
  (implicit) claim; this is bitblocks' (explicit) one.
  """
  def verification(collection_id) do
    origins =
      from(i in Item, where: i.collection_id == ^collection_id, select: i.origin)
      |> Repo.all()
      |> Enum.sort()

    height =
      Repo.one(
        from i in Item, where: i.collection_id == ^collection_id, select: max(i.mint_height)
      )

    %{
      by: "bitblocks",
      basis: "mint_contract_chain",
      rule: config_for(collection_id).protocol.rule(),
      list_hash: :crypto.hash(:sha256, Enum.join(origins, "\n")) |> Base.encode16(case: :lower),
      items: length(origins),
      verified_through_height: height
    }
  end

  @doc "Items for many outpoints (origin or current), keyed by the outpoint asked."
  def lookup(collection_id, outpoints) do
    items =
      Repo.all(
        from i in Item,
          where:
            i.collection_id == ^collection_id and
              (i.origin in ^outpoints or i.current_outpoint in ^outpoints)
      )

    Enum.reduce(items, %{}, fn item, acc ->
      acc |> Map.put_new(item.current_outpoint, item) |> Map.put_new(item.origin, item)
    end)
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
