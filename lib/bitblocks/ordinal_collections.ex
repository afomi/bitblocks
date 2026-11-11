defmodule Bitblocks.OrdinalCollections do
  @moduledoc """
  NFT collections with proven membership and traced ownership (#30): Grand
  Tardinians (1Sat, `OneSat`), Rexxies and other RelayX collections (Run,
  `RunJig`, #79), and Rare Candy's (`RareCandy`, #77). Each collection is one
  row of `@collections`; one with no hint (`hint: :none`) is found by walking
  its chain through our spend index alone.

  **Membership is proven, not claimed.** Both kinds mint through a chain: each
  mint spends the collection's current link (Bubblemint's mint contract, or a
  Run class jig) and carries it on. The engine walks that chain from the
  collection's first link; the protocol decides from the bytes whether a tx
  mints and where the chain goes next. A copycat that claims the collection
  (a MAP `collectionId`, a look-alike name) can't spend the chain.

  **Discovery** takes a hint list of mint txids (GorillaPool's search, or a
  catalog; see `Release.sync_ordinal_collection/1`), imports them, walks the
  chain locally, and follows past the hint's end through our spend index, so
  an item the hint missed is still found and a fake in the hint is rejected.

  **Ownership** follows each item from its origin through spends (`trace/1`);
  the protocol says where a spent item lands (a 1Sat sat by input offset, a
  Run jig by the payload's output order). What it can't decide from the bytes
  is `unknown`, never guessed; where the trail truly ends (a Run jig spent
  outside Run) is `ended`. A lookup that fails never erases what an earlier
  trace found.

  **Our own index answers; WhatsOnChain only supplies bytes** (docs/WOC_USE.md).
  Where an outpoint went comes from `spend_index` by the `Chain.Utxos` rule:
  a spend row whose spender is in a block we store is a fact, and no row
  means unspent only when our index is complete through our tip. Anything
  else stops the walk or trace there, with a reason naming the height our
  index reaches (`partial`, or `untraced` for an item never placed), and is
  never filled from WhatsOnChain. Transactions are read from our index first;
  only a missing tx's raw bytes are fetched from WhatsOnChain (`Woc.txs/1`),
  and every imported body is checked against its txid.

  **Batches (`trace_batch/1`)** trace hop by hop across their items: one
  spend-index lookup for every item's outpoint, then one bulk, deduplicated
  fetch of the raw txs that hop needs and we lack. An item still where the
  last trace left it costs one lookup and no tx read. Each batch reports its
  counts (`stats`): spend lookups, local tx reads, raw txs fetched and
  WhatsOnChain requests.

  **Memory (#47).** A walk touches every tx of a collection, and a mint's tx
  holds its whole inscription. What a protocol reads from a tx (a name, a
  content type, a trait) is a slice of those bytes and keeps all of them alive
  for as long as it is referenced, so nothing read from a tx may outlive its
  hop: `sync/3` writes each mint's items as it walks and keeps only counts, and
  `settle/0` drops each hop's garbage. `measure/1` reports the high-water mark,
  recorded on the walk (`peak_bytes`, `trace_peak_bytes`).
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawBlock, RawTx, Transaction, TxIngest, Utxos}
  alias Bitblocks.OrdinalCollections.{Item, Walk}
  alias Bitblocks.Ordinals.Inscription
  alias Bitblocks.{Repo, TxStore, Woc}
  alias Bitblocks.Workers.CollectionTraceWorker

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
    },
    # RelayX COL classes (`class COL extends RelayNFT {}`, `isCollection`),
    # found from relayx.com/market pages in the Wayback Machine (#79). No
    # catalog: items are unnamed, and each image is the mint's B:// file.
    "pixmoji" => %{
      id: "8637b04add2ef6f788ab0b91559438ea51c1540324eb7bb6541fda3a66d97cb4_2",
      name: "PixMoji",
      description: "Pixel representations of emoji, a numbered Run collection.",
      standard: "Run",
      source: "RelayX",
      protocol: Bitblocks.OrdinalCollections.RunJig,
      hint: :none
    },
    "glossy-spheres" => %{
      id: "81e2b29195bd1298874318fc16c739bd13adca7f64c59ced1ae69d644cd2ef20_2",
      name: "Glossy Spheres",
      description: "A numbered Run collection of glossy spheres.",
      standard: "Run",
      source: "RelayX",
      protocol: Bitblocks.OrdinalCollections.RunJig,
      hint: :none
    },
    # Rare Candy (#77): the id is the collection tx's B:// output, and `link`
    # the mint outpoint it declares (`RareCandy.mint_outpoints/1`).
    "planetary-skies" => %{
      id: "b9a47ebfeba619a97ddf44ef5bd4b3546bf05bf52391cd828154b19896811b52_0",
      link: "c2f602dd3b9b40661a5373beb567010069eca20251f6be98a6737e4ac1bbfaf9_0",
      name: "Planetary Skies",
      description: "99 generative planetary sky NFTs.",
      standard: "Rare Candy",
      source: "Rare Candy",
      protocol: Bitblocks.OrdinalCollections.RareCandy,
      hint: :none
    },
    "astro-apes" => %{
      id: "7aaf5700968b4c5f78de43873f3450d6566d7f4463056090ad16ff51340f6509_0",
      link: "6dd1e23e666a01b5171bd4bc145a89ca403845ae48fec22595409255a7a7ee3c_0",
      name: "Astro Apes",
      description:
        "Astro Apes Space Force: 2,000 randomly generated apes, Rare Candy's first drop.",
      standard: "Rare Candy",
      source: "Rare Candy",
      protocol: Bitblocks.OrdinalCollections.RareCandy,
      hint: :none
    },
    "oni-society" => %{
      id: "9f4b93e97ca5905c0f01a8e6446d1c0f45f42bdc47704bb5cdc09c6b874f77b0_0",
      link: "8967ca5a90895f93b6f642ef8e02701fa460a75713944f53b7d2970305c5abb1_0",
      name: "Oni Society",
      description: "2,222 Oni: Noble, Shade or Death.",
      standard: "Rare Candy",
      source: "Rare Candy",
      protocol: Bitblocks.OrdinalCollections.RareCandy,
      hint: :none
    },
    "fox-syndicate" => %{
      id: "20d0f7e0f64cd5a9e6a12687a29ee896d5f487fe4e8f458798fcacceb4dca3c5_0",
      link: "167f86753b57664d4cc01ace9cd32da5e4ed38c66d7ad5cbc5d4a54d3812cc61_0",
      name: "Fox Syndicate",
      description: "4,444 feral NFT foxes.",
      standard: "Rare Candy",
      source: "Rare Candy",
      protocol: Bitblocks.OrdinalCollections.RareCandy,
      hint: :none
    }
  }

  # Where BSV collections are minted and traded. `url` is set only for an
  # address confirmed to be the platform (checked 2026-11-01): rarecandy.com is
  # an unrelated trading-card shop and bubblemint.com is a parked domain.
  @sources [
    %{
      name: "RelayX",
      url: nil,
      description:
        "Run-based NFT marketplace where Rexxies, PixMoji and Glossy Spheres were minted and traded.",
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
      description:
        "NFT launchpad and marketplace, home of the Oni Society and Astro Apes drops, " <>
          "with its own token format: each item is locked to its collection's transaction.",
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

  # The process dictionary key of the high-water mark while `measure/1` runs.
  @peak {__MODULE__, :peak_bytes}

  # The process dictionary key of a trace batch's counts while it runs.
  @stats {__MODULE__, :trace_stats}

  # Process dictionary keys: the index coverage a sync or trace batch is
  # judged against, a hop's input values by txid, and the input txs a
  # landing's first pass found missing.
  @coverage {__MODULE__, :coverage}
  @values {__MODULE__, :input_values}
  @missing {__MODULE__, :missing_inputs}

  # trace_all/1 reads items a page at a time.
  @trace_page 100

  # Item rows per insert (13 columns each, under Postgres's 65,535 parameters).
  @insert_batch 1_000

  # Items in one queued re-trace, as in a collection sync's trace batches.
  @retrace_batch 10

  @rewound_reason "a reorg replaced a block on this item's trail; the next trace redoes it"

  @doc "Transfers followed per trace before stopping as `partial`."
  def max_hops, do: @max_hops

  @doc "Known collections: slug => collection id (origin outpoint)."
  def known, do: Map.new(@collections, fn {slug, config} -> {slug, config.id} end)

  @doc "Where BSV collections are minted and traded."
  def sources, do: @sources

  # Trace states that are final answers: the item sits at a known outpoint
  # now, or its trail ends. Every other state may still move.
  @settled_states ["current", "ended"]

  @doc "Whether a trace state is a final answer (`current` or `ended`)."
  def settled_state?(state), do: state in @settled_states

  @doc """
  Every collection we know or hold items for, by name: known collections even
  before their first sync, then any other indexed collection origin. Counts
  come from the index: `traced` is items whose trace is settled (`current`,
  or `ended`: traced to where the trail ends), and `ended` the latter alone.
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
        traced: @settled_states |> Enum.map(&(states[&1] || 0)) |> Enum.sum(),
        ended: states["ended"] || 0
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
      count(:woc_requests)
      count(:raw_txs_fetched, length(batch))

      case Woc.txs(batch) do
        {:ok, txs} ->
          returned = MapSet.new(txs, & &1["txid"])
          absent = for t <- batch, not MapSet.member?(returned, t), do: {t, :not_returned}
          heights = our_heights(txs)

          Enum.reduce(txs, %{acc | failed: absent ++ acc.failed}, fn tx, acc ->
            block = %Block{
              hash: tx["blockhash"],
              height: Map.get(heights, tx["blockhash"], tx["blockheight"])
            }

            with {:ok, json} <- own_json(tx),
                 :ok <- TxIngest.store(json, block) do
              %{acc | stored: acc.stored + 1}
            else
              {:error, reason} -> %{acc | failed: [{tx["txid"], reason} | acc.failed]}
            end
          end)

        {:error, reason} ->
          %{acc | failed: Enum.map(batch, &{&1, reason}) ++ acc.failed}
      end
    end)
    |> tap(fn _ -> keep_blobs(txids) end)
  end

  # The row is built from the bytes, not from WhatsOnChain's decoded JSON:
  # only the bytes are checked (against the txid), so the inputs, outputs and
  # the spend rows they write are read by us.
  defp own_json(%{"txid" => txid, "hex" => hex}) when is_binary(txid) and is_binary(hex) do
    with true <- TxIngest.body_matches_txid?(hex, txid),
         {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
      {:ok, RawBlock.tx_json(txid, bytes)}
    else
      _ -> {:error, :body_mismatch}
    end
  rescue
    _ -> {:error, :undecodable}
  end

  defp own_json(_tx), do: {:error, :no_hex}

  # Block hash => height, for the blocks WhatsOnChain names that we hold: the
  # height is ours where we have the header, WhatsOnChain's only where not.
  defp our_heights(txs) do
    hashes = for %{"blockhash" => h} <- txs, is_binary(h), uniq: true, do: h

    if hashes == [],
      do: %{},
      else:
        Repo.all(from b in Block, where: b.hash in ^hashes, select: {b.hash, b.height})
        |> Map.new()
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
  hint through our spend index. A link our index can't answer for yet (its
  spend may sit above `Sync.complete_through/0`) ends the walk there as not
  `complete`.

  Returns `%{mints, items, rejected, import, complete, peak_bytes}`:
  `rejected` counts hinted txs that are not on the mint chain, `complete` says
  the walk reached the end of the chain with no lookup failing (recorded for
  `absence/2`), and `peak_bytes` is the most this process held above where it
  started.

  Items are written as the walk reaches them, in chain order, so the walk
  holds counts and not transactions. A walk that stops early keeps the items
  it proved; every one of them is on the chain.
  """
  def sync(collection_id, hint_txids, opts \\ []) do
    {{walk, import}, peak} =
      measure(fn ->
        [collection_txid, _] = String.split(collection_id, "_")
        import = import_txs([collection_txid | hint_txids])
        spenders = spender_index(hint_txids)
        config = config_for(collection_id)

        with_coverage(fn ->
          {walk_chain(config, spenders, Keyword.get(opts, :follow, true)), import}
        end)
      end)

    mints = MapSet.size(walk.mint_ids)
    rejected = hint_txids |> Enum.uniq() |> Enum.count(&(not MapSet.member?(walk.mint_ids, &1)))
    record_walk(collection_id, walk.complete?, mints, walk.items, peak)

    Logger.info(
      "OrdinalCollections.sync #{collection_id}: #{mints} mints, #{walk.items} items, " <>
        "#{rejected} hinted txs rejected, #{peak} bytes at peak"
    )

    %{
      mints: mints,
      items: walk.items,
      rejected: rejected,
      import: import,
      complete: walk.complete?,
      peak_bytes: peak
    }
  end

  @doc """
  Runs `fun` and returns `{result, peak_bytes}`: the most this process held
  above where it started (its heap and the binaries it references), sampled at
  each hop of a walk or trace.
  """
  def measure(fun) do
    :erlang.garbage_collect()
    start = process_bytes()
    Process.put(@peak, start)
    result = fun.()
    settle()
    {result, max(Process.delete(@peak) - start, 0)}
  end

  # A hop's end: notes the high-water mark, then frees what the hop left, so
  # one large tx is gone before the next is read. The heap of a walking process
  # is small, so this costs little beside the lookups around it.
  defp settle do
    if peak = Process.get(@peak), do: Process.put(@peak, max(peak, process_bytes()))
    :erlang.garbage_collect()
    :ok
  end

  defp process_bytes do
    {:memory, heap} = Process.info(self(), :memory)
    {:binary, binaries} = Process.info(self(), :binary)
    heap + (binaries |> Enum.map(&elem(&1, 1)) |> Enum.sum())
  end

  @doc """
  Records a trace batch's high-water mark on the collection's walk, keeping
  the highest of the run. No walk on record, nothing to do.
  """
  def record_trace_peak(collection_id, peak) when is_integer(peak) do
    from(w in Walk,
      where: w.collection_id == ^collection_id,
      update: [set: [trace_peak_bytes: fragment("GREATEST(?, ?)", w.trace_peak_bytes, ^peak)]]
    )
    |> Repo.update_all([])

    :ok
  end

  # An unfinished walk clears the record: `absence/2` must not answer from a
  # chain we could no longer follow.
  defp record_walk(collection_id, false, _mints, _items, _peak) do
    Repo.delete_all(from w in Walk, where: w.collection_id == ^collection_id)
  end

  defp record_walk(collection_id, true, mints, items, peak) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %Walk{
        collection_id: collection_id,
        finished_at: now,
        mints: mints,
        items: items,
        peak_bytes: peak,
        trace_peak_bytes: nil
      },
      on_conflict:
        {:replace, [:finished_at, :mints, :items, :peak_bytes, :trace_peak_bytes, :updated_at]},
      conflict_target: :collection_id
    )
  end

  # outpoint ("txid_vout") => spending txid, over the candidate txs we hold.
  defp spender_index(txids) do
    txids
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn txid, index ->
      index =
        case load_tx(txid) do
          {:ok, tx, _height} ->
            Enum.reduce(tx.inputs, index, &Map.put(&2, outpoint_id(&1.outpoint), txid))

          _ ->
            index
        end

      settle()
      index
    end)
  end

  # Breadth-first from the collection outpoint: each chain link is spent by at
  # most one tx, and the protocol decides whether that tx mints and where the
  # chain goes next. Txs that carry the chain on without minting are walked
  # through but aren't mints. Each mint's items are indexed as it is reached,
  # so the walk holds no tx past its hop. Returns `%{mint_ids, items,
  # complete?}`: complete? is false when a link couldn't be followed, which is
  # not the same as the chain ending.
  defp walk_chain(config, spenders, follow?) do
    walk = %{mint_ids: MapSet.new(), items: 0, complete?: true}
    do_walk([first_link(config)], spenders, follow?, config, MapSet.new(), walk)
  end

  defp do_walk([], _spenders, _follow?, _config, _seen, walk), do: walk

  defp do_walk([link | queue], spenders, follow?, config, seen, walk) do
    settle()

    with {:ok, spender} <- spender_of(link, spenders, follow?),
         false <- MapSet.member?(seen, spender),
         {:ok, tx, height} <- load_tx(spender),
         {:ok, items, next_links} <- config.protocol.mint(tx, spender, link, config) do
      walk = index_mint(walk, config.id, spender, height, items)
      seen = MapSet.put(seen, spender)
      do_walk(queue ++ next_links, spenders, follow?, config, seen, walk)
    else
      # The link is unspent, already walked, or spent by a tx that ends the chain.
      ended when ended in [:unspent, true, :no] ->
        do_walk(queue, spenders, follow?, config, seen, walk)

      _ ->
        do_walk(queue, spenders, follow?, config, seen, %{walk | complete?: false})
    end
  end

  # The chain's first link: the collection id, unless the collection names
  # its mint outpoint separately (Rare Candy: the id is the collection tx).
  defp first_link(config), do: Map.get(config, :link, config.id)

  # A tx that only carries the chain on isn't a mint.
  defp index_mint(walk, _cid, _txid, _height, []), do: walk

  defp index_mint(walk, cid, txid, height, items) do
    %{
      walk
      | mint_ids: MapSet.put(walk.mint_ids, txid),
        items: walk.items + index_items(cid, txid, height, items)
    }
  end

  defp spender_of(link, spenders, follow?) do
    case spenders[link] do
      nil -> follow_spend(link, follow?)
      spender -> {:ok, spender}
    end
  end

  defp follow_spend(_link, false), do: :not_followed

  # Past the hint, the chain goes where our spend index says. A link it
  # can't answer for leaves the walk incomplete; WhatsOnChain isn't asked.
  defp follow_spend(link, true) do
    op = parse_outpoint(link)

    case spend_statuses([op])[op] do
      %{status: :spent, spent_by: spender} ->
        import_txs([spender])
        {:ok, spender}

      %{status: :unspent} ->
        :unspent

      status ->
        {:error, unknown_reason(link, status)}
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
          image_txid: item[:image_txid],
          current_outpoint: origin,
          owner: item[:owner],
          trace_state: "untraced",
          inserted_at: now,
          updated_at: now
        }
      end

    # Re-sync refreshes metadata but keeps ownership traced so far. A Rare
    # Candy mint holds thousands of items, so rows go in batches under
    # Postgres's parameter limit.
    rows
    |> Enum.chunk_every(@insert_batch)
    |> Enum.reduce(0, fn batch, total ->
      {count, _} =
        Repo.insert_all(Item, batch,
          on_conflict:
            {:replace, [:name, :content_type, :traits, :image_txid, :mint_height, :updated_at]},
          conflict_target: [:collection_id, :origin]
        )

      total + count
    end)
  end

  # -- Ownership -----------------------------------------------------------------

  @doc """
  Follows `item`'s sat from where we last saw it (its origin, if never traced)
  to where it sits now, and records the owner. Returns the updated item.
  One item's `trace_batch/1`.

  The trace states:

    * `current`: the item sits at `current_outpoint`, held by `owner`: our
      index is complete through our tip and records no spend of it.
    * `ended`: the trail truly ends at `current_outpoint`, e.g. a Run jig
      spent outside Run. Final, and settled like `current`; `owner` is nil.
    * `partial`: stopped at `current_outpoint`: a long trail, a lookup that
      failed after the item moved, or our index can't say yet whether it
      moved on (`trace_reason` names the height it reaches). The next trace
      resumes there.
    * `unknown`: the protocol can't say where the item went (`trace_reason`).
    * `untraced`: never placed past its origin; `trace_reason`, when set,
      says why (our index can't answer for the origin yet).

  Where an outpoint went comes from our spend index only (the
  `Chain.Utxos` rule); WhatsOnChain only supplies the raw bytes of a tx we
  lack. A lookup that fails (a spending tx or an input's tx we can't fetch)
  never erases what an earlier trace found (#46): an item with a known
  location keeps it, its owner and its state, and the failure is recorded in
  `trace_error` and `trace_checked_at` so a later run retries. `traced_at`
  dates the last trace that answered.

  A trace writes only if the row is as it read it (`trace_version`, #73): when
  a reorg marked the item meanwhile, the mark stands and this returns the row
  as it now is, or `{:error, :gone}` when the reorg removed the item.
  """
  @spec trace(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, :gone}
  def trace(%Item{} = item, opts \\ []) do
    case trace_batch([{item, opts}]) do
      {:ok, [:gone], _stats} -> {:error, :gone}
      {:ok, [traced], _stats} -> {:ok, traced}
    end
  end

  @doc """
  Traces items together, hop by hop: every item's next outpoint is looked up
  in `spend_index` at once, the raw txs that hop needs and we lack are fetched
  in bulk with duplicates removed, and then the next hop. `entries` are items,
  or `{item, opts}` with `trace/2`'s options.

  Returns `{:ok, items, stats}`: the updated items in the order given (`:gone`
  in place of one a reorg removed while it was traced, #73), and the batch's
  counts: `items`, `hops` (hop rounds), `spend_lookups`
  (outpoints looked up in our spend index), `tx_reads` (txs read from our
  index), `raw_txs_fetched` (txids asked of WhatsOnChain) and
  `woc_requests` (its bulk raw-tx requests).
  """
  @spec trace_batch([Item.t() | {Item.t(), keyword()}]) :: {:ok, [Item.t() | :gone], map()}
  def trace_batch(entries) when is_list(entries) do
    Process.put(@stats, %{
      items: length(entries),
      hops: 0,
      spend_lookups: 0,
      tx_reads: 0,
      raw_txs_fetched: 0,
      woc_requests: 0
    })

    try do
      with_coverage(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        items =
          entries
          |> Enum.map(&walker/1)
          |> walk_hops()
          |> Enum.map(&record(&1, now))

        {:ok, items, Process.get(@stats)}
      end)
    after
      Process.delete(@stats)
    end
  end

  # One item's walk: where it started, where it is now, the spending txids
  # it moved through (newest first) and, once it stops, its result: one of
  # {:current, outpoint}, {state, outpoint, owner, reason},
  # {:beyond_index, outpoint, reason} or {:failed, outpoint, error}.
  defp walker(%Item{} = item), do: walker({item, []})

  defp walker({%Item{} = item, opts}) do
    # current, ended: re-check from where it sat; partial: resume where the last
    # trace stopped; otherwise (or with from: :origin) start from the origin,
    # which rebuilds the trail.
    resume? =
      Keyword.get(opts, :from) != :origin and item.trace_state in ["current", "ended", "partial"] and
        item.current_outpoint != nil

    start = if resume?, do: item.current_outpoint, else: item.origin

    %{
      item: item,
      resume?: resume?,
      start: start,
      protocol: config_for(item.collection_id).protocol,
      at: start,
      steps: [],
      hops: 0,
      result: nil
    }
  end

  defp walk_hops(walkers) do
    walkers = Enum.map(walkers, &stop_long/1)

    case for(%{result: nil, at: at} <- walkers, do: parse_outpoint(at)) do
      [] -> walkers
      active -> walkers |> hop(active) |> walk_hops()
    end
  end

  defp stop_long(%{result: nil, hops: hops} = w) when hops >= @max_hops do
    reason = "stopped after #{@max_hops} transfers; the next trace continues from here"
    %{w | result: {"partial", w.at, nil, reason}}
  end

  defp stop_long(w), do: w

  # One hop for every walker still moving: one spend-index lookup for all
  # their outpoints, one bulk fetch of the spending txs we lack, then one of
  # the input txs their landings read.
  defp hop(walkers, active) do
    settle()
    count(:hops)
    statuses = spend_statuses(active)

    txs =
      spending_txs(
        for %{status: :spent, spent_by: by} <- Map.values(statuses), uniq: true, do: by
      )

    keys =
      for %{result: nil, at: at, protocol: protocol} <- walkers,
          %{status: :spent, spent_by: by, spent_by_vin: vin} <- [statuses[parse_outpoint(at)]],
          uniq: true,
          do: {protocol, by, vin}

    landings = landings(keys, txs)

    walkers
    |> Enum.map(fn
      %{result: nil} = w -> step(w, statuses[parse_outpoint(w.at)], landings)
      w -> w
    end)
    |> tap(fn _ -> Process.delete(@values) end)
  end

  defp step(w, %{status: :unspent}, _landings), do: %{w | result: {:current, w.at}}

  defp step(w, %{status: :spent, spent_by: spender, spent_by_vin: vin}, landings) do
    w = %{w | steps: [spender | w.steps]}

    case landings[{w.protocol, spender, vin}] do
      {:ok, next} -> %{w | at: next, hops: w.hops + 1}
      {:ended, reason} -> %{w | result: {"ended", w.at, nil, reason}}
      {:unknown, reason} -> %{w | result: {"unknown", w.at, nil, reason}}
      {:error, reason} -> %{w | result: {:failed, w.at, reason}}
      _ -> %{w | result: {:failed, w.at, "spending tx #{spender} unavailable"}}
    end
  end

  defp step(w, status, _landings),
    do: %{w | result: {:beyond_index, w.at, unknown_reason(w.at, status)}}

  # txid => load_tx result, fetching the raw txs we lack in one bulk import.
  defp spending_txs([]), do: %{}

  defp spending_txs(txids) do
    import_txs(txids)
    Map.new(txids, &{&1, load_tx(&1)})
  end

  # {protocol, spender, vin} => the protocol's landing. A first pass reads
  # input values from our index only and notes the txs it lacks; those are
  # fetched in one bulk import, and the second pass answers.
  defp landings([], _txs), do: %{}

  defp landings(keys, txs) do
    Process.put(@missing, MapSet.new())
    Enum.each(keys, &land(&1, txs, fn op -> probe_value(op) end))
    missing = Process.delete(@missing) |> MapSet.to_list()
    if missing != [], do: import_txs(missing)

    Map.new(keys, &{&1, land(&1, txs, fn op -> output_value(op) end)})
  end

  defp land({protocol, spender, vin}, txs, value_of) do
    case txs[spender] do
      {:ok, tx, _height} -> protocol.landing(tx, spender, vin, value_of)
      _ -> :unavailable
    end
  end

  # An input's value from our index, or 0 with its txid noted as missing (the
  # first pass's answers are thrown away).
  defp probe_value(op) do
    case local_value(op) do
      {:ok, sats} ->
        {:ok, sats}

      :error ->
        Process.put(@missing, MapSet.put(Process.get(@missing), BSV.OutPoint.get_txid(op)))
        {:ok, 0}
    end
  end

  # Builds the item's new row from where its walk stopped.
  defp record(%{item: item, resume?: resume?, start: start} = w, now) do
    steps = Enum.reverse(w.steps)

    changes =
      case w.result do
        {:failed, at, error} ->
          failed_changes(item, resume?, start, at, steps, error)

        {:beyond_index, at, reason} ->
          beyond_index_changes(item, resume?, at, steps, reason, now)

        {:current, at} ->
          {state, outpoint, owner, reason} = placed(w, at)
          answered(item, resume?, steps, state, outpoint, owner, reason, now)

        {state, outpoint, owner, reason} ->
          answered(item, resume?, steps, state, outpoint, owner, reason, now)
      end

    # Compare-and-set on trace_version (#73): a reorg that marked the item
    # while this trace walked has bumped it, and the mark wins. The re-trace
    # that mark queued starts from the origin.
    item
    |> Ecto.Changeset.change(Map.put(changes, :trace_checked_at, now))
    |> Ecto.Changeset.optimistic_lock(:trace_version)
    |> Repo.update(stale_error_field: :trace_version)
    |> case do
      {:ok, traced} ->
        traced

      {:error, %Ecto.Changeset{}} ->
        case Repo.get(Item, item.id) do
          nil -> :gone
          current -> current
        end
    end
    # The owner read a tx; drop it before the next item's.
    |> tap(fn _ -> settle() end)
  end

  # Unspent at `at`. An item still where the last trace put it keeps the
  # owner read then, from the same bytes, so it costs no tx read.
  defp placed(%{item: %Item{trace_state: "current", current_outpoint: at} = item}, at),
    do: {"current", at, item.owner, item.trace_reason}

  defp placed(w, at) do
    case owner_at(at, w.protocol) do
      nil -> {"current", at, nil, "held by a non-P2PKH lock (e.g. a marketplace listing)"}
      owner -> {"current", at, owner, nil}
    end
  end

  defp answered(item, resume?, steps, state, outpoint, owner, reason, now) do
    %{
      trace_state: state,
      current_outpoint: outpoint,
      owner: owner,
      trail: trail(item, resume?, steps),
      trace_reason: reason,
      trace_source: "index",
      traced_at: now,
      trace_error: nil
    }
  end

  # Our index can't say yet whether `at` is spent. That is an answer, not a
  # failure: the item stops there with the reason, as `partial` (resumed
  # there next time) or, never placed past its origin, `untraced`.
  defp beyond_index_changes(item, resume?, at, steps, reason, now) do
    if at == item.origin and not resume? and steps == [] do
      %{
        trace_state: "untraced",
        current_outpoint: at,
        owner: nil,
        trail: [],
        trace_reason: reason,
        trace_source: "index",
        traced_at: now,
        trace_error: nil
      }
    else
      %{
        trace_state: "partial",
        current_outpoint: at,
        owner: nil,
        trail: trail(item, resume?, steps),
        trace_reason: "#{reason}; the next trace continues from here",
        trace_source: "index",
        traced_at: now,
        trace_error: nil
      }
    end
  end

  defp trail(item, true, steps), do: Enum.uniq((item.trail || []) ++ steps)
  defp trail(_item, false, steps), do: steps

  # A failed lookup at `at`, after walking `steps` from `start`.
  defp failed_changes(item, resume?, start, at, steps, error) do
    cond do
      # Nothing new learned: keep the last answer, whatever it was. An ended
      # item's spend is already on its trail.
      at == start and item.trace_state != "untraced" and
          (steps == [] or item.trace_state == "ended") ->
        %{trace_error: error}

      # Never traced, and stuck at the origin: nothing to keep.
      at == item.origin and not resume? and steps == [] ->
        %{
          trace_state: "unknown",
          current_outpoint: at,
          owner: nil,
          trail: [],
          trace_reason: error,
          trace_source: nil,
          trace_error: error
        }

      # The item got to `at` (or is known spent from it); resume there.
      true ->
        %{
          trace_state: "partial",
          current_outpoint: at,
          owner: nil,
          trail: trail(item, resume?, steps),
          trace_reason: "#{error}; the next trace continues from here",
          trace_source: "index",
          trace_error: error
        }
    end
  end

  @doc """
  Traces every item of a collection, a page at a time (each page one
  `trace_batch/1`). Returns counts by trace_state.
  """
  def trace_all(collection_id), do: trace_pages(collection_id, 0, %{})

  defp trace_pages(collection_id, after_id, counts) do
    page =
      from(i in Item,
        where: i.collection_id == ^collection_id and i.id > ^after_id,
        order_by: i.id,
        limit: @trace_page
      )
      |> Repo.all()

    case page do
      [] ->
        counts

      page ->
        {:ok, traced, _stats} = trace_batch(page)

        counts =
          Enum.reduce(traced, counts, fn
            %Item{trace_state: state}, counts -> Map.update(counts, state, 1, &(&1 + 1))
            # A reorg removed the item while it was traced.
            :gone, counts -> counts
          end)

        trace_pages(collection_id, List.last(page).id, counts)
    end
  end

  # -- Reorgs (#52, #53) ---------------------------------------------------------
  #
  # Membership and ownership both rest on txs, so each item answers for the txs
  # it touches: its mint, its trail and the tx it sits in.
  #
  #   * An item minted by a tx no block holds isn't on the chain: it goes. The
  #     next sync finds it again if the mint is mined later.
  #   * An item with a hop no block holds goes back to `untraced` at its origin
  #     and a re-trace is queued. A trail records txids, not the output an item
  #     left in, so the only sound place to restart is the origin.
  #   * A re-mined tx keeps its bytes. A mint keeps its item, at its new height;
  #     a hop sends the item back only when its protocol says so
  #     (`retrace_moved?/0`: yes for Run, no for 1Sat).
  #
  # Every other item keeps its answer, settled or not. Marking is idempotent: a
  # marked item touches nothing but its mint.

  @doc """
  What `rewind_moved/2` and `rewind_removed/1` would change. Read-only.
  `moved` counts mints moved, `removed` items gone, `retrace` items marked.
  """
  @spec rewind_plan([String.t()], [String.t()]) :: %{
          moved: non_neg_integer(),
          removed: non_neg_integer(),
          retrace: non_neg_integer()
        }
  def rewind_plan(moved, removed) do
    {minted, gone, retrace} = rewind_targets(moved, removed)
    %{moved: length(minted), removed: length(gone), retrace: length(retrace)}
  end

  @doc """
  Txs in `txids` now sit in the block at `block_height`: moves their mints
  there and marks the items whose protocol redoes such a trail. Returns the
  counts of `rewind_plan/2`.
  """
  @spec rewind_moved([String.t()], integer()) :: %{
          moved: non_neg_integer(),
          removed: 0,
          retrace: non_neg_integer()
        }
  def rewind_moved(txids, block_height) do
    {minted, _gone, retrace} = rewind_targets(txids, [])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {moved, _} =
      Repo.update_all(
        from(i in Item, where: i.id in ^Enum.map(minted, & &1.id)),
        set: [mint_height: block_height, updated_at: now]
      )

    mark_for_retrace(retrace)
    %{moved: moved, removed: 0, retrace: length(retrace)}
  end

  @doc """
  No block holds the txs in `txids`: deletes the items they minted and marks
  the items with a hop among them. Returns the counts of `rewind_plan/2`.
  """
  @spec rewind_removed([String.t()]) :: %{
          moved: 0,
          removed: non_neg_integer(),
          retrace: non_neg_integer()
        }
  def rewind_removed(txids) do
    {_minted, gone, retrace} = rewind_targets([], txids)

    {removed, _} = Repo.delete_all(from(i in Item, where: i.id in ^Enum.map(gone, & &1.id)))
    mark_for_retrace(retrace)
    %{moved: 0, removed: removed, retrace: length(retrace)}
  end

  # {items minted by a moved tx, items minted by a removed tx, items to mark}.
  # Reads the items once and matches here: collections are thousands of items,
  # and the txids can be a whole block.
  defp rewind_targets([], []), do: {[], [], []}

  defp rewind_targets(moved, removed) do
    moved = MapSet.new(moved)
    removed = MapSet.new(removed)

    items =
      Repo.all(
        from(i in Item,
          select: struct(i, [:id, :collection_id, :mint_txid, :current_outpoint, :trail])
        )
      )

    {gone, kept} = Enum.split_with(items, &MapSet.member?(removed, &1.mint_txid))
    minted = Enum.filter(kept, &MapSet.member?(moved, &1.mint_txid))

    retrace =
      Enum.filter(kept, fn item ->
        hops = hops(item)
        redo_moved? = config_for(item.collection_id).protocol.retrace_moved?()

        Enum.any?(hops, &MapSet.member?(removed, &1)) or
          (redo_moved? and Enum.any?(hops, &MapSet.member?(moved, &1)))
      end)

    {minted, gone, retrace}
  end

  # The txs an item's current answer rests on.
  defp hops(%Item{mint_txid: mint, current_outpoint: outpoint, trail: trail}) do
    at = if outpoint, do: outpoint |> String.split("_") |> hd()
    Enum.reject([mint, at | trail || []], &is_nil/1)
  end

  defp mark_for_retrace([]), do: :ok

  defp mark_for_retrace(items) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(i in Item,
        where: i.id in ^Enum.map(items, & &1.id),
        update: [
          set: [
            trace_state: "untraced",
            current_outpoint: i.origin,
            owner: nil,
            trail: [],
            trace_reason: ^@rewound_reason,
            trace_source: nil,
            traced_at: nil,
            trace_error: nil,
            trace_checked_at: nil,
            updated_at: ^now
          ],
          inc: [trace_version: 1]
        ]
      ),
      []
    )

    started = DateTime.to_iso8601(now)

    for {cid, in_collection} <- Enum.group_by(items, & &1.collection_id),
        batch <- Enum.chunk_every(in_collection, @retrace_batch) do
      ids = Enum.map(batch, & &1.id)
      Oban.insert!(CollectionTraceWorker.new(%{slug: cid, ids: ids, run_started_at: started}))
    end

    :ok
  end

  # -- Our index -----------------------------------------------------------------

  # {txid, vout} => its `Chain.Utxos.outpoints/2` status, with the coverage it
  # was judged against (`through`, `tip`).
  defp spend_statuses([]), do: %{}

  defp spend_statuses(ops) do
    ops = Enum.uniq(ops)
    count(:spend_lookups, length(ops))

    %{outpoints: statuses, indexed_through_height: through, tip_height: tip} =
      Utxos.outpoints(ops, coverage())

    Map.new(statuses, fn {op, status} ->
      {op, Map.merge(status, %{through: through, tip: tip})}
    end)
  end

  # Why our index can't say where `outpoint` went, naming the height it reaches.
  defp unknown_reason(outpoint, %{unknown_reason: :not_indexed_yet, tip: nil}),
    do: "our index holds no block headers yet, so the spend of #{outpoint} can't be looked up"

  defp unknown_reason(outpoint, %{unknown_reason: :not_indexed_yet, through: through, tip: tip})
       when through < 0,
       do:
         "no spend of #{outpoint} in our spend index, which isn't complete from block 0 " <>
           "yet (tip #{tip}); a spend in any block may not be indexed yet"

  defp unknown_reason(outpoint, %{unknown_reason: :not_indexed_yet, through: through, tip: tip}),
    do:
      "no spend of #{outpoint} in our spend index, which is complete through block " <>
        "#{through} of #{tip}; a spend from block #{through + 1} on isn't indexed yet"

  defp unknown_reason(outpoint, %{unknown_reason: {:spender_not_in_stored_block, by}}),
    do: "#{outpoint} is spent by #{by}, which isn't in a block we store"

  defp unknown_reason(outpoint, %{unknown_reason: :tx_not_in_stored_block}),
    do: "#{outpoint |> String.split("_") |> hd()} isn't in a block we store"

  defp unknown_reason(outpoint, _status),
    do: "our index can't say whether #{outpoint} is spent"

  # The coverage a sync or a trace batch judges every outpoint against, read
  # once for it (`Sync.complete_through/0` counts blocks).
  defp with_coverage(fun) do
    Process.put(@coverage, Utxos.coverage())

    try do
      fun.()
    after
      Process.delete(@coverage)
    end
  end

  defp coverage, do: Process.get(@coverage) || Utxos.coverage()

  defp count(key, n \\ 1) do
    case Process.get(@stats) do
      %{} = stats -> Process.put(@stats, Map.update(stats, key, n, &(&1 + n)))
      nil -> :ok
    end
  end

  defp parse_outpoint(outpoint) do
    [txid, vout] = String.split(outpoint, "_")
    {txid, String.to_integer(vout)}
  end

  # Value of an outpoint from our index, importing its tx if we don't hold it.
  defp output_value(op) do
    with :error <- local_value(op) do
      import_txs([BSV.OutPoint.get_txid(op)])
      local_value(op)
    end
  end

  # Value of an outpoint from a tx we hold; remembered for the hop.
  defp local_value(%BSV.OutPoint{vout: vout} = op) do
    txid = BSV.OutPoint.get_txid(op)
    values = Process.get(@values, %{})

    case values do
      %{^txid => sats} ->
        sats_at(sats, vout)

      _ ->
        case load_tx(txid) do
          {:ok, tx, _} ->
            sats = Enum.map(tx.outputs, & &1.satoshis)
            Process.put(@values, Map.put(values, txid, sats))
            sats_at(sats, vout)

          _ ->
            :error
        end
    end
  end

  defp sats_at(sats, vout) do
    case Enum.at(sats, vout) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp owner_at(outpoint, protocol) do
    {txid, vout} = parse_outpoint(outpoint)

    with {:ok, tx, _} <- load_tx(txid),
         %BSV.TxOut{} = out <- Enum.at(tx.outputs, vout) do
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
  The layers of layered items, by item id: each a `/content/<outpoint>` path,
  bottom first. Some collections inscribe traits separately, and an item is
  an SVG that only stacks them (`<image href="/content/<outpoint>">`). An SVG
  shown through `<img>` may not load anything, so a page has to stack the
  layers itself. Read from the mint txs we hold; an item that isn't layered,
  or whose tx we can't read, has no entry.
  """
  def layers(items) do
    for %Item{content_type: "image/svg+xml"} = item <- items,
        layers = item_layers(item),
        layers != [],
        into: %{} do
      {item.id, layers}
    end
  end

  defp item_layers(item) do
    [txid, vout] = String.split(item.origin, "_")

    with {:ok, bytes} <- TxStore.raw(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes)),
         %BSV.TxOut{script: script} <- Enum.at(tx.outputs, String.to_integer(vout)),
         {:ok, %{content: svg}} when is_binary(svg) <- Inscription.parse(script) do
      svg_layers(svg)
    else
      _ -> []
    end
  end

  @doc """
  The `/content/<outpoint>` paths an SVG stacks, or `[]` unless stacking
  inscriptions is all it does. Inscriptions are untrusted: only the outpoints
  are taken from the bytes, and the paths are built here.
  """
  def svg_layers(svg) when is_binary(svg) do
    layered =
      ~r|\A\s*<svg\b[^>]*>(\s*<image href="/content/[0-9a-f]{64}_\d+"[^>]*/>)+\s*</svg>\s*\z|

    if String.valid?(svg) and svg =~ layered do
      for [outpoint] <-
            Regex.scan(~r|<image href="/content/([0-9a-f]{64}_\d+)"|, svg,
              capture: :all_but_first
            ) do
        "/content/#{outpoint}"
      end
    else
      []
    end
  end

  @doc """
  Where an item's image is served from: the catalog's for a collection whose
  on-chain payloads aren't viewable (Rexxies are encrypted), else the B://
  file the mint names (`image_txid`), else the inscription itself. Nil when
  none is an image.
  """
  def image_path(%Item{} = item) do
    case config_for(item.collection_id) do
      %{catalog: catalog} ->
        with %{number: number} <- catalog.entry(item.mint_txid) do
          Bitblocks.Rexxies.image_path(%{"number" => number})
        end

      _ ->
        cond do
          item.image_txid -> "/b/#{item.image_txid}"
          match?("image/" <> _, item.content_type) -> "/content/#{item.origin}"
          true -> nil
        end
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

  `false` needs a finished chain walk and every item's trace settled
  (`current` or `ended`): an item with an unfinished trace could sit anywhere
  past its last known location.
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
      from i in Item,
        where: i.collection_id == ^collection_id and i.trace_state not in @settled_states
    )
  end

  @doc """
  The ownership claim in words, separate from membership: an indexed item's
  membership stands whatever this says. A mint's owner is only where the item
  started, so nothing reads as held until a trace reaches it.
  """
  def ownership_sentence(%Item{trace_state: "current", owner: owner}) when is_binary(owner),
    do: "Held by #{owner}."

  def ownership_sentence(%Item{trace_state: "untraced", trace_reason: nil}),
    do: "Not traced yet."

  def ownership_sentence(%Item{trace_state: "ended", trace_reason: reason}),
    do: "No holder: #{reason}."

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
    count(:tx_reads)

    with %{} = row <-
           Repo.one(
             from t in Transaction,
               where: t.txid == ^txid,
               select: map(t, [:txid, :raw, :block_height])
           ),
         %{raw: raw, block_height: height} when is_binary(raw) and raw != "" <-
           TxStore.with_raw(row),
         {:ok, tx} <- RawTx.parse(raw) do
      {:ok, tx, height}
    else
      _ -> :error
    end
  end

  defp outpoint_id(%BSV.OutPoint{vout: vout} = op), do: "#{BSV.OutPoint.get_txid(op)}_#{vout}"
end
