defmodule Bitblocks.Elections do
  @moduledoc """
  An election read from our index (`docs/ELECTION_DOGFOOD.md`): its records
  gathered from stored txs, counted live, and archived when it closes
  (`Bitblocks.Elections.Archive`). Read only: Bitblocks never signs or sends.

  `gather/2` finds the election record by its outpoint, its roll by the
  outpoint the election names, and its ballots among the stored txs tagged
  `MAP` (the `protocols` GIN column), or matching a projection's
  filter when one is given, between the election's block and
  `closes_at_height + 6`. Every query is bounded: by txid, or by tag and
  height, a page at a time, up to `:election_max_scanned` rows.

  Each record's height is the block it sits in when that block is the one our
  headers hold at that height; otherwise (a reorg moved it) it is nil, as the
  count expects. `position` is the tx's index in its block, read from its
  merkle proof (`Chain.MerkleProof`), which the archive keeps as a BUMP.

  What a count can see is what our index holds, so every answer says how far
  that reaches: `complete_through` (every block stored), and, when a
  projection is given, how far its tip lane has read (`Bitblocks.TipLane`).
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Headers, MerkleProof, Transaction}
  alias Bitblocks.Elections.{Count, Records}
  alias Bitblocks.Projections.Projection
  alias Bitblocks.{Projections, Repo, Sync, TipLane, TxStore}

  # Blocks past closes_at_height before an archive may be built, and the
  # last height a ballot is gathered from: every ballot in the archive then
  # has its header in the archive.
  @depth 6
  @page 500
  @default_max_scanned 50_000

  @doc "Blocks past `closes_at_height` before the archive: #{@depth}."
  @spec depth() :: pos_integer()
  def depth, do: @depth

  @doc """
  The election at `election_outpoint` (`<txid>.<vout>`), its roll and its
  ballots, as found in our index.

  Options: `projection:` a projection id (or struct) whose filter matches the
  election's ballots, to search by its filter and count its tip lane in the
  coverage.

  Returns `{:ok, gathered}` with `election`, `roll` and `ballots` (each with
  its count input under `input`, and `txid`, `vout`, `block_hash`, `proof`
  and `bytes`), the window searched, and `coverage`. Errors:
  `:invalid_outpoint`, `{:not_found, :election | :roll}`,
  `{:not_a_record, :election | :roll, reason}`, `:election_unconfirmed`,
  `:roll_sha256_mismatch`, `:roll_not_signed_by_administrator`,
  `{:too_many_candidates, max}`, `{:proof_unavailable, txid, reason}`.
  """
  @spec gather(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def gather(election_outpoint, opts \\ []) do
    with {:ok, {txid, vout}} <- outpoint(election_outpoint),
         {:ok, projection} <- projection(opts[:projection]),
         {:ok, election} <- record(txid, vout, :election),
         {:ok, election} <- confirmed_election(election, election_outpoint),
         {:ok, roll} <- roll(election),
         window = window(election),
         coverage = coverage(window, projection),
         {:ok, ballots} <- ballots(election_outpoint, window, coverage, projection) do
      {:ok,
       %{
         election: election_outpoint,
         app: Records.app(),
         administrator: election.signer,
         election_record: election,
         roll: roll,
         ballots: ballots,
         window: window,
         coverage: coverage
       }}
    end
  end

  @doc """
  The count as of now: `gather/2`, then `Count.count/4`, with the block the
  count is current to.

  Returns `{:ok, %{election, count, current_to: %{height, hash}, final,
  close_block_hash, coverage}}`. `final` is true once our index covers every
  block through `closes_at_height + #{@depth}`. `close_block_hash` is the
  hash of the block at `closes_at_height` once we hold it, which settles a
  tie by lot. A refusal from the count comes back as it is.
  """
  @spec count_now(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def count_now(election_outpoint, opts \\ []) do
    with {:ok, gathered} <- gather(election_outpoint, opts) do
      count(gathered)
    end
  end

  @doc """
  Counts what `gather/2` found, as `count_now/2` does; the archive counts with
  this too, so both give one answer from one input.
  """
  @spec count(map()) :: {:ok, map()} | {:error, term()}
  def count(gathered) do
    %{election: election_input, roll: roll_input, ballots: ballots, close_block_hash: close} =
      inputs(gathered)

    opts = if close, do: [close_block_hash: close], else: []

    with {:ok, result} <- Count.count(election_input, roll_input, ballots, opts) do
      current = gathered.coverage.current_to

      {:ok,
       %{
         election: gathered.election,
         count: result,
         current_to: %{height: current, hash: block_hash_at(current)},
         final: gathered.coverage.complete,
         close_block_hash: close,
         coverage: gathered.coverage
       }}
    end
  end

  @doc """
  The exact input `Count.count/4` is given for a gathered election:
  `election`, `roll`, `ballots` and `close_block_hash` (nil until we hold the
  block at `closes_at_height`).
  """
  @spec inputs(map()) :: %{
          election: map(),
          roll: map(),
          ballots: [map()],
          close_block_hash: String.t() | nil
        }
  def inputs(gathered) do
    closes = gathered.election_record.input["closes_at_height"]

    %{
      election: gathered.election_record.input,
      roll: gathered.roll.input,
      ballots: Enum.map(gathered.ballots, & &1.input),
      close_block_hash: canonical_hash_at(closes)
    }
  end

  @doc """
  Where our index holds the tx `txid`, for a ballot lookup that found no
  ballot by that txid in the count: `nil` when we don't store it, else
  `%{height: h, block_hash: hash}` (height nil while it is in no block).
  One query by txid; it reads no bytes.
  """
  @spec stored_at(String.t()) :: nil | %{height: integer() | nil, block_hash: String.t() | nil}
  def stored_at(txid) when is_binary(txid) do
    Repo.one(
      from(t in Transaction,
        where: t.txid == ^txid,
        select: %{height: t.block_height, block_hash: t.block_hash},
        limit: 1
      )
    )
  end

  # -- The records ------------------------------------------------------------

  defp outpoint(value) do
    case Records.outpoint(value) do
      {:ok, parts} -> {:ok, parts}
      :error -> {:error, :invalid_outpoint}
    end
  end

  defp projection(nil), do: {:ok, nil}
  defp projection(%Projection{source: "transactions"} = projection), do: {:ok, projection}
  defp projection(%Projection{}), do: {:error, :projection_not_transactions}

  defp projection(id) when is_integer(id) do
    case Projections.get(id) do
      nil -> {:error, {:not_found, :projection}}
      projection -> projection(projection)
    end
  end

  # One record by outpoint, with its bytes checked against its txid, its
  # canonical height, and its proof.
  defp record(txid, vout, kind) do
    with {:row, %Transaction{} = row} <- {:row, Repo.one(row_query(txid))},
         {:ok, bytes} <- bytes(row),
         {:ok, %{kind: ^kind} = parsed} <- parse(bytes, vout, kind),
         {:ok, placed} <- place(row) do
      {:ok, Map.merge(placed, %{record: parsed, signer: parsed.signer, vout: vout, bytes: bytes})}
    else
      {:row, nil} -> {:error, {:not_found, kind}}
      {:error, _} = error -> error
    end
  end

  defp row_query(txid) do
    from(t in Transaction,
      where: t.txid == ^txid,
      select: struct(t, [:txid, :raw, :raw_in_db, :block_hash, :block_height]),
      limit: 1
    )
  end

  defp bytes(%Transaction{txid: txid, raw: raw}) do
    result =
      if is_binary(raw) and raw != "",
        do: Base.decode16(String.trim(raw), case: :mixed),
        else: TxStore.raw(txid)

    case result do
      {:ok, bytes} ->
        if TxStore.txid(bytes) == txid, do: {:ok, bytes}, else: {:error, {:bytes_mismatch, txid}}

      _ ->
        {:error, {:raw_unavailable, txid}}
    end
  end

  defp parse(bytes, vout, kind) do
    case Records.parse_output(bytes, vout) do
      {:ok, %{kind: ^kind} = record} -> {:ok, record}
      {:ok, %{kind: other}} -> {:error, {:not_a_record, kind, {:wrong_type, other}}}
      {:error, reason} -> {:error, {:not_a_record, kind, reason}}
    end
  end

  # Where a stored tx sits on the chain our headers hold: its height,
  # block hash, index in the block and proof; height nil when its block is
  # not the one we hold at that height (a reorg moved it).
  defp place(%Transaction{txid: txid, block_height: height, block_hash: hash}) do
    if canonical?(height, hash) do
      case MerkleProof.build(txid) do
        {:ok, proof} ->
          {:ok,
           %{txid: txid, height: height, block_hash: hash, position: proof.index, proof: proof}}

        {:error, :not_canonical} ->
          {:ok, unplaced(txid, hash)}

        {:error, reason} ->
          {:error, {:proof_unavailable, txid, reason}}
      end
    else
      {:ok, unplaced(txid, hash)}
    end
  end

  defp unplaced(txid, hash),
    do: %{txid: txid, height: nil, block_hash: hash, position: nil, proof: nil}

  defp canonical?(height, hash) when is_integer(height) and is_binary(hash) do
    case Headers.at(height) do
      %{hash: held, canonical: true} when is_binary(held) ->
        String.downcase(held) == String.downcase(hash)

      _ ->
        false
    end
  end

  defp canonical?(_height, _hash), do: false

  defp confirmed_election(%{height: nil}, _outpoint), do: {:error, :election_unconfirmed}

  defp confirmed_election(election, outpoint) do
    input =
      election.record.fields
      |> Map.put("election", outpoint)
      |> Map.put("height", election.height)

    {:ok, Map.put(election, :input, input)}
  end

  defp roll(election) do
    %{"roll" => roll_outpoint, "roll_sha256" => expected} = election.record.fields
    {:ok, {txid, vout}} = Records.outpoint(roll_outpoint)

    with {:ok, roll} <- record(txid, vout, :roll) do
      cond do
        roll.record.fields["sha256"] != expected ->
          {:error, :roll_sha256_mismatch}

        roll.signer != election.signer ->
          {:error, :roll_not_signed_by_administrator}

        true ->
          input = %{"members" => roll.record.fields["members"], "height" => roll.height}
          {:ok, Map.merge(roll, %{outpoint: roll_outpoint, input: input})}
      end
    end
  end

  # -- The ballots ------------------------------------------------------------

  defp window(election) do
    %{"opens_at_height" => opens, "closes_at_height" => closes} = election.record.fields

    %{
      from_height: election.height,
      opens_at_height: opens,
      closes_at_height: closes,
      to_height: closes + @depth
    }
  end

  defp ballots(election_outpoint, window, coverage, projection) do
    to = min(window.to_height, coverage.covered_through)

    if to < window.from_height do
      {:ok, []}
    else
      base = Projections.query(projection || tag_projection())

      with {:ok, rows} <- scan(base, window.from_height, to) do
        rows
        |> Enum.flat_map(&ballot_record(&1, election_outpoint))
        |> Enum.reduce_while({:ok, []}, fn {row, bytes, parsed}, {:ok, acc} ->
          case place(row) do
            {:ok, placed} -> {:cont, {:ok, [ballot(placed, parsed, bytes) | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ballots} -> {:ok, Enum.sort_by(ballots, &order_key/1)}
          error -> error
        end
      end
    end
  end

  # The ballots' tag: MAP. Not AIP too, since a ballot with no signature is
  # still a ballot, listed as no_signature.
  defp tag_projection, do: %Projection{filter: %{"protocols" => ["MAP"]}}

  # Keyset pages over (block_height, txid) in the height range, so no page
  # costs more than the first, up to the configured bound.
  defp scan(base, from, to) do
    max = Application.get_env(:bitblocks, :election_max_scanned, @default_max_scanned)
    do_scan(base, from, to, nil, max, [])
  end

  defp do_scan(base, from, to, after_key, max, acc) do
    query =
      from(t in base,
        where: t.block_height >= ^from and t.block_height <= ^to,
        order_by: [asc: t.block_height, asc: t.txid],
        limit: @page,
        select: struct(t, [:txid, :raw, :raw_in_db, :block_hash, :block_height])
      )

    query =
      case after_key do
        nil ->
          query

        {h, txid} ->
          where(query, [t], fragment("(?, ?) > (?, ?)", t.block_height, t.txid, ^h, ^txid))
      end

    rows = Repo.all(query)
    acc = acc ++ rows

    cond do
      length(acc) > max ->
        {:error, {:too_many_candidates, max}}

      length(rows) < @page ->
        {:ok, acc}

      true ->
        last = List.last(rows)
        do_scan(base, from, to, {last.block_height, last.txid}, max, acc)
    end
  end

  # The tx's first ballot naming this election, or nothing.
  defp ballot_record(row, election_outpoint) do
    with {:ok, bytes} <- bytes(row),
         {:ok, records} <- Records.parse_tx(bytes),
         %{} = parsed <-
           Enum.find(
             records,
             &(&1.kind == :ballot and &1.fields["election"] == election_outpoint)
           ) do
      [{row, bytes, parsed}]
    else
      _ -> []
    end
  end

  defp ballot(placed, parsed, bytes) do
    input = %{
      "txid" => placed.txid,
      "election" => parsed.fields["election"],
      "height" => placed.height,
      "position" => placed.position,
      "signer" => parsed.signer,
      "choices" => parsed.fields["choices"]
    }

    Map.merge(placed, %{
      vout: parsed.vout,
      record: parsed,
      signer: parsed.signer,
      bytes: bytes,
      input: input
    })
  end

  defp order_key(%{height: nil, txid: txid}), do: {1, 0, 0, txid}
  defp order_key(%{height: h, position: p, txid: txid}), do: {0, h, p, txid}

  # -- Coverage ---------------------------------------------------------------

  defp coverage(window, projection) do
    tip = Sync.tip()
    complete = Sync.complete_through(tip)
    lane = projection && TipLane.get(projection.id)
    lane_through = lane && TipLane.through(lane, tip)
    covered = max(complete, lane_through || -1)

    %{
      complete_through: complete,
      tip_lane_through_height: lane_through,
      projection_id: projection && projection.id,
      covered_through: covered,
      tip_height: tip,
      current_to: min(covered, window.to_height),
      complete: covered >= window.to_height
    }
  end

  defp block_hash_at(height) when is_integer(height) and height >= 0 do
    case Headers.at(height) do
      %{hash: hash} -> hash
      nil -> nil
    end
  end

  defp block_hash_at(_height), do: nil

  # The hash of the block at `height`, in RPC and display order, when our
  # headers hold it and it is canonical.
  defp canonical_hash_at(height) when is_integer(height) do
    case Headers.at(height) do
      %{hash: hash, canonical: true} when is_binary(hash) -> String.downcase(hash)
      _ -> nil
    end
  end
end
