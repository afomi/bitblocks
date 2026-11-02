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
  alias Bitblocks.OrdinalCollections.{Item, Walk}
  alias Bitblocks.{Repo, Woc}

  # id: the chain's first link (the collection's origin outpoint).
  # hint: where candidate mint txids come from (only candidates; see sync/3).
  @collections %{
    "grand-tardinians" => %{
      id: "f099182e168c0a30a9f97556d156c8b6284cfc3f76eca8352807b1ceff29da04_0",
      name: "Grand Tardinians",
      description: "A 1Sat ordinal collection minted through a Bubblemint mint contract.",
      standard: "1Sat",
      source: "Bubblemint",
      protocol: Bitblocks.OrdinalCollections.OneSat,
      hint: :gorillapool
    },
    "rexxies" => %{
      # The Rexxie COL class (`…_o2` in Run notation).
      id: "12d8ca4bc0eaf26660627cc1671de6a0047246f39f3aa06633f8204223d70cc5_2",
      name: "Rexxies",
      description: "2,222 unique dinosaur NFTs built with Run protocol.",
      standard: "Run",
      source: "RelayX",
      protocol: Bitblocks.OrdinalCollections.RunJig,
      catalog: Bitblocks.Rexxies.Catalog,
      hint: :catalog
    }
  }

  # Where BSV collections are minted and traded. `url` is set only for an
  # address confirmed to be the platform (checked 2026-11-01): rarecandy.com is
  # an unrelated trading-card shop and bubblemint.com is a parked domain.
  @sources [
    %{
      name: "RelayX",
      url: nil,
      description: "Run-based NFT marketplace where Rexxies were minted and traded.",
      status: "relayx.com returned 404 when last checked."
    },
    %{
      name: "Twetch",
      url: "https://twetch.com/market",
      description: "On-chain social network with an NFT market, including Twonks and Sigils.",
      status: nil
    },
    %{
      name: "Rare Candy",
      url: "https://rarecandy.io",
      description: "NFT launchpad and marketplace, home of the Oni Society and Astro Apes drops.",
      status: nil
    },
    %{
      name: "Bubblemint",
      url: "https://www.bubblemint.io",
      description: "Minting platform for 1Sat collections, including Tardinians and Pixel Foxes.",
      status: nil
    },
    %{
      name: "Zoide",
      url: "https://zoide.io/market/collections",
      description: "BSV NFT marketplace with drops, listings, and rankings.",
      status: nil
    }
  ]

  # Per trace. A longer trail stops as "partial" and the next trace resumes.
  @max_hops 100

  @doc "Transfers followed per trace before stopping as `partial`."
  def max_hops, do: @max_hops

  @doc "Known collections: slug => collection id (origin outpoint)."
  def known, do: Map.new(@collections, fn {slug, config} -> {slug, config.id} end)

  @doc "Where BSV collections are minted and traded."
  def sources, do: @sources

  @doc """
  Every collection we know or hold items for, by name: known collections even
  before their first sync, then any other indexed collection origin. Counts
  come from the index; `traced` is items whose location is `current`.
  """
  def list_collections do
    counts =
      from(i in Item,
        group_by: [i.collection_id, i.trace_state],
        select: {i.collection_id, i.trace_state, count()}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_cid, state, n} -> {state, n} end)

    known =
      for {slug, config} <- @collections do
        config |> Map.take([:id, :name, :description, :standard, :source]) |> Map.put(:slug, slug)
      end

    known_ids = MapSet.new(known, & &1.id)

    indexed =
      for cid <- Map.keys(counts), not MapSet.member?(known_ids, cid) do
        %{id: cid, slug: cid, name: cid, description: nil, standard: "1Sat", source: nil}
      end

    (known ++ indexed)
    |> Enum.map(fn collection ->
      states = Map.new(counts[collection.id] || [])

      Map.merge(collection, %{
        items: states |> Map.values() |> Enum.sum(),
        traced: states["current"] || 0
      })
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "One entry of `list_collections/0` by slug or collection id; nil if unknown."
  def get_collection(slug_or_id) do
    with cid when is_binary(cid) <- resolve(slug_or_id) do
      Enum.find(list_collections(), &(&1.id == cid))
    end
  end

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

  Returns `%{mints, items, rejected, import, complete}`: `rejected` counts
  hinted txs that are not on the mint chain, and `complete` says the walk
  reached the end of the chain with no lookup failing (recorded for
  `absence/2`).
  """
  def sync(collection_id, hint_txids, opts \\ []) do
    [collection_txid, _] = String.split(collection_id, "_")
    import = import_txs([collection_txid | hint_txids])

    spenders = spender_index(hint_txids)
    config = config_for(collection_id)
    {mints, complete?} = walk_chain(config, spenders, Keyword.get(opts, :follow, true))

    items =
      mints
      |> Enum.map(fn {txid, height, items} -> index_items(collection_id, txid, height, items) end)
      |> Enum.sum()

    mint_ids = MapSet.new(mints, &elem(&1, 0))
    rejected = hint_txids |> Enum.uniq() |> Enum.count(&(not MapSet.member?(mint_ids, &1)))
    record_walk(collection_id, complete?, length(mints), items)

    Logger.info(
      "OrdinalCollections.sync #{collection_id}: #{length(mints)} mints, #{items} items, " <>
        "#{rejected} hinted txs rejected"
    )

    %{mints: length(mints), items: items, rejected: rejected, import: import, complete: complete?}
  end

  # An unfinished walk clears the record: `absence/2` must not answer from a
  # chain we could no longer follow.
  defp record_walk(collection_id, false, _mints, _items) do
    Repo.delete_all(from w in Walk, where: w.collection_id == ^collection_id)
  end

  defp record_walk(collection_id, true, mints, items) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %Walk{collection_id: collection_id, finished_at: now, mints: mints, items: items},
      on_conflict: {:replace, [:finished_at, :mints, :items, :updated_at]},
      conflict_target: :collection_id
    )
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
  # through but aren't mints. Returns {mints, complete?}: complete? is false
  # when a link couldn't be followed, which is not the same as the chain ending.
  defp walk_chain(config, spenders, follow?) do
    do_walk([config.id], spenders, follow?, config, MapSet.new(), [], true)
  end

  defp do_walk([], _spenders, _follow?, _config, _seen, mints, complete?),
    do: {Enum.reverse(mints), complete?}

  defp do_walk([link | queue], spenders, follow?, config, seen, mints, complete?) do
    with {:ok, spender} <- spender_of(link, spenders, follow?),
         false <- MapSet.member?(seen, spender),
         {:ok, tx, height} <- load_tx(spender),
         {:ok, items, next_links} <- config.protocol.mint(tx, spender, link, config) do
      mints = if items == [], do: mints, else: [{spender, height, items} | mints]
      seen = MapSet.put(seen, spender)
      do_walk(queue ++ next_links, spenders, follow?, config, seen, mints, complete?)
    else
      # The link is unspent, already walked, or spent by a tx that ends the chain.
      ended when ended in [:unspent, true, :no] ->
        do_walk(queue, spenders, follow?, config, seen, mints, complete?)

      _ ->
        do_walk(queue, spenders, follow?, config, seen, mints, false)
    end
  end

  defp spender_of(link, spenders, follow?) do
    case spenders[link] do
      nil -> follow_spend(link, follow?)
      spender -> {:ok, spender}
    end
  end

  defp follow_spend(_link, false), do: :not_followed

  defp follow_spend(link, true) do
    [txid, vout] = String.split(link, "_")

    case Woc.spent(txid, String.to_integer(vout)) do
      {:ok, %{txid: spender}} ->
        import_txs([spender])
        {:ok, spender}

      {:ok, :unspent} ->
        :unspent

      {:error, reason} ->
        {:error, reason}
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
    # Unknown with no step means WhatsOnChain gave no spend answer at all.
    source = if state == "unknown" and steps == [], do: nil, else: "whatsonchain"

    item
    |> Ecto.Changeset.change(%{
      trace_state: state,
      current_outpoint: outpoint,
      owner: owner,
      trail: trail,
      trace_reason: reason,
      trace_source: source,
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

  @doc """
  A numbered page of items in mint order, for browsing. Options: `:page`,
  `:per_page`, `:q` (matches the name or a trait value), `:trait` (a
  `{name, value}` pair). Returns `{items, total}`.
  """
  def browse_items(collection_id, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 50)
    page = opts |> Keyword.get(:page, 1) |> max(1)

    query =
      from(i in Item, where: i.collection_id == ^collection_id)
      |> search_items(opts[:q])
      |> filter_trait(opts[:trait])

    items =
      query
      |> order_by(asc: :id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, Repo.aggregate(query, :count)}
  end

  defp search_items(query, q) when q in [nil, ""], do: query

  defp search_items(query, q) do
    like = "%#{String.replace(q, ~r/[%_\\\\]/, "\\\\\\0")}%"

    where(
      query,
      [i],
      ilike(i.name, ^like) or
        fragment("EXISTS (SELECT 1 FROM unnest(?) t WHERE t->>'value' ILIKE ?)", i.traits, ^like)
    )
  end

  defp filter_trait(query, nil), do: query

  defp filter_trait(query, {name, value}) do
    where(
      query,
      [i],
      fragment(
        "EXISTS (SELECT 1 FROM unnest(?) t WHERE t->>'name' = ? AND t->>'value' = ?)",
        i.traits,
        ^name,
        ^value
      )
    )
  end

  @doc "Figures for a collection's page: trait types, and distinct traced holders."
  def stats(collection_id) do
    %{rows: [[trait_types]]} =
      Repo.query!(
        "SELECT count(DISTINCT t->>'name') FROM collection_items i, unnest(i.traits) t " <>
          "WHERE i.collection_id = $1",
        [collection_id]
      )

    holders =
      Repo.one(
        from i in Item,
          where: i.collection_id == ^collection_id and i.trace_state == "current",
          select: count(i.owner, :distinct)
      )

    %{trait_types: trait_types, holders: holders}
  end

  @doc """
  Where an item's image is served from: the catalog's for a collection whose
  on-chain payloads aren't viewable (Rexxies are encrypted), else the
  inscription itself. Nil when neither is an image.
  """
  def image_path(%Item{} = item) do
    case config_for(item.collection_id) do
      %{catalog: catalog} ->
        with %{number: number} <- catalog.entry(item.mint_txid) do
          Bitblocks.Rexxies.image_path(%{"number" => number})
        end

      _ ->
        if match?("image/" <> _, item.content_type), do: "/content/#{item.origin}"
    end
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

  @doc """
  What can be said about outpoints that `lookup/2` didn't find, keyed by
  outpoint: `{false, reason}` or `{"unknown", reason}`.

  `false` needs a finished chain walk and every item's trace settled: an item
  with an unfinished trace could sit anywhere past its last known location.
  An outpoint of a tx on an item's trail stays unknown, because the trail
  records txids and not which output the item left in.
  """
  def absence(collection_id, outpoints) do
    txids = Enum.map(outpoints, &(&1 |> String.split("_") |> hd()))

    on_trail =
      from(i in Item,
        where:
          i.collection_id == ^collection_id and
            fragment("? && ?", i.trail, type(^txids, {:array, :string})),
        select: i.trail
      )
      |> Repo.all()
      |> List.flatten()
      |> MapSet.new()

    walk = Repo.one(from w in Walk, where: w.collection_id == ^collection_id)
    settled? = walk != nil and not unsettled_items?(collection_id)

    Map.new(outpoints, fn outpoint ->
      txid = outpoint |> String.split("_") |> hd()

      answer =
        cond do
          MapSet.member?(on_trail, txid) ->
            {"unknown", "an item moved through this transaction; the output is not recorded"}

          settled? ->
            {false,
             "not an item of this collection as of #{DateTime.to_iso8601(walk.finished_at)}"}

          true ->
            {"unknown", "not an indexed item of this collection (or its sync is incomplete)"}
        end

      {outpoint, answer}
    end)
  end

  defp unsettled_items?(collection_id) do
    Repo.exists?(
      from i in Item, where: i.collection_id == ^collection_id and i.trace_state != "current"
    )
  end

  @doc """
  The ownership claim in words, separate from membership: an indexed item's
  membership stands whatever this says. A mint's owner is only where the item
  started, so nothing reads as held until a trace reaches it.
  """
  def ownership_sentence(%Item{trace_state: "current", owner: owner}) when is_binary(owner),
    do: "Held by #{owner}."

  def ownership_sentence(%Item{trace_state: "untraced"}), do: "Not traced yet."

  def ownership_sentence(%Item{trace_reason: "whatsonchain: " <> _}),
    do: "Owner unknown: WhatsOnChain did not answer."

  def ownership_sentence(%Item{trace_reason: reason}) when is_binary(reason),
    do: "Owner unknown: #{reason}."

  def ownership_sentence(%Item{}), do: "Owner unknown."

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
