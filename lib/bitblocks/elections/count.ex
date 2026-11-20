defmodule Bitblocks.Elections.Count do
  @moduledoc """
  The election counting rule (`docs/ELECTION_DOGFOOD.md`), as a pure function.

  It takes the election record, the roll and every ballot seen, and says for
  each ballot whether it counted and, if not, the first rule it failed; then the
  tally per candidate and the winners. It reads no database, chain or clock, so
  the live page, the archive and a third-party recount get the same answer from
  the same input. The published vectors,
  `priv/data/interop/election_count_v0.json` (served at
  `/interop/elections/count/v0.json`), hold it to that.

  Inputs use string keys, as the records decode from JSON, with MAP's decimal
  strings already read as integers:

    * election: `"election"` (its id: the election record's outpoint,
      `<txid>.<vout>`), `"name"`, `"number_elected"`, `"votes_allowed"`
      (optional, defaults to `"number_elected"`), `"candidates"` (each `"id"`
      of `a-z`, `0-9` and `-`, and `"name"`), `"opens_at_height"`,
      `"closes_at_height"`, `"roll"` (the roll file's outpoint), `"roll_sha256"`
      (over the roll file's exact bytes on chain), and `"height"` (optional, the
      block the election record confirmed in).
    * roll: `"members"`, the P2PKH addresses allowed to vote, sorted and each
      once, compared as exact strings; and `"height"` (optional, the block the
      roll confirmed in).
    * ballot: `"txid"`, `"election"` (the election's outpoint), `"height"` (nil
      while unconfirmed or after a reorg drops its block), `"position"` (the
      tx's index in its block, coinbase 0, the same as its BUMP leaf offset),
      `"signer"` (the address whose AIP signature checked over every MAP field,
      nil when none did) and `"choices"` (candidate ids).

  Each ballot meets the rules in `rules/0` order, and the first one it fails is
  its `rule`:

    * `other_election`: it names a different election.
    * `no_signature`: no AIP signature checked.
    * `not_on_roll`: its signer isn't on the roll.
    * `unconfirmed`: it isn't in a block.
    * `before_open` / `after_close`: its block is outside
      `opens_at_height..closes_at_height` (both ends count).
    * `malformed_choices`: `choices` isn't a list of strings.
    * `too_many_choices`: it names more than `votes_allowed` candidates.
    * `duplicate_choice`: it names one candidate twice.
    * `unknown_candidate`: it names an id not on the election's list.
    * `replaced`: the same signer has a later ballot, in chain order
      (height, then position), that passed every rule above.

  A ballot that fails an earlier rule never replaces another. An empty
  `choices` passes, votes for no one, and so withdraws the signer's earlier
  votes.

  Winners: candidates with at least one vote, most votes first, up to
  `number_elected`. When candidates tie for the last seats, the tie is settled
  by lot from the hash of the block at `closes_at_height` (`close_block_hash`,
  lowercase hex in RPC and display order, the reverse of the header's internal
  byte order): the tied candidates are ordered by
  `sha256("<close_block_hash>:<candidate id>")` as lowercase hex, lowest first.
  Without that hash (while voting is open) those seats are `undecided`.
  Candidates tied above the boundary all win, listed in the election's order.
  """

  @typedoc "Why a ballot didn't count."
  @type rule ::
          :other_election
          | :no_signature
          | :not_on_roll
          | :unconfirmed
          | :before_open
          | :after_close
          | :malformed_choices
          | :too_many_choices
          | :duplicate_choice
          | :unknown_candidate
          | :replaced

  @type ballot_result :: %{
          txid: String.t(),
          counted: boolean(),
          rule: rule() | nil,
          replaced_by: String.t() | nil
        }

  @type result :: %{
          election: String.t(),
          ballots: [ballot_result()],
          counted: non_neg_integer(),
          not_counted: non_neg_integer(),
          tally: [%{candidate: String.t(), votes: non_neg_integer()}],
          winners: [String.t()],
          undecided: nil | %{seats: pos_integer(), tied: [String.t()]}
        }

  @type input_error ::
          {:invalid_election, String.t()}
          | {:invalid_roll, String.t()}
          | {:invalid_ballot, String.t() | nil, String.t()}

  @rules [
    :other_election,
    :no_signature,
    :not_on_roll,
    :unconfirmed,
    :before_open,
    :after_close,
    :malformed_choices,
    :too_many_choices,
    :duplicate_choice,
    :unknown_candidate,
    :replaced
  ]

  # Every refusal, as {kind, detail}. The published vectors hold one for each.
  @e_not_map "election must be a map"
  @e_id "election must be an outpoint: <txid>.<vout>, lowercase hex and a decimal vout"
  @e_number_elected "number_elected must be a positive integer"
  @e_votes_allowed "votes_allowed, when given, must be a positive integer"
  @e_candidates "candidates must be a list, each with a string id"
  @e_candidate_id "candidate ids must be one or more of a-z, 0-9 and -"
  @e_candidate_unique "candidate ids must be unique"
  @e_roll_outpoint "roll must be the roll file's outpoint: <txid>.<vout>"
  @e_roll_sha256 "roll_sha256 must be 64 lowercase hex characters"
  @e_heights "opens_at_height and closes_at_height must be non-negative integers"
  @e_backwards "closes_at_height is before opens_at_height"
  @e_election_height "the election record must confirm below opens_at_height"
  @r_not_map "roll must be a map with members"
  @r_strings "members must be strings"
  @r_unique "members must be unique"
  @r_sorted "members must be sorted"
  @r_height "the roll must confirm below opens_at_height"
  @b_list "ballots must be a list"
  @b_txid "each ballot needs a string txid"
  @b_height "height must be a non-negative integer or null"
  @b_position "a confirmed ballot needs a non-negative position"
  @b_twice "txid appears twice"
  @b_slot "another ballot has this height and position"

  @refusals [
    {:invalid_election, @e_not_map},
    {:invalid_election, @e_id},
    {:invalid_election, @e_number_elected},
    {:invalid_election, @e_votes_allowed},
    {:invalid_election, @e_candidates},
    {:invalid_election, @e_candidate_id},
    {:invalid_election, @e_candidate_unique},
    {:invalid_election, @e_roll_outpoint},
    {:invalid_election, @e_roll_sha256},
    {:invalid_election, @e_heights},
    {:invalid_election, @e_backwards},
    {:invalid_election, @e_election_height},
    {:invalid_roll, @r_not_map},
    {:invalid_roll, @r_strings},
    {:invalid_roll, @r_unique},
    {:invalid_roll, @r_sorted},
    {:invalid_roll, @r_height},
    {:invalid_ballot, @b_list},
    {:invalid_ballot, @b_txid},
    {:invalid_ballot, @b_height},
    {:invalid_ballot, @b_position},
    {:invalid_ballot, @b_twice},
    {:invalid_ballot, @b_slot}
  ]

  @outpoint ~r/\A[0-9a-f]{64}\.(0|[1-9][0-9]*)\z/
  @candidate_id ~r/\A[a-z0-9-]+\z/
  @sha256_hex ~r/\A[0-9a-f]{64}\z/

  @doc "Every rule a ballot can fail, in the order they're applied."
  @spec rules() :: [rule()]
  def rules, do: @rules

  @doc "Every refusal of a whole input, as `{kind, detail}`."
  @spec refusals() :: [{atom(), String.t()}]
  def refusals, do: @refusals

  @doc """
  Counts `ballots` for `election` against `roll`.

  Options: `close_block_hash`, the hash of the block at `closes_at_height` in
  RPC and display order, which settles a tie for the last seats.

  Returns `{:error, reason}` when the input itself can't be a real election
  (`refusals/0` lists each one): a malformed election, an election or roll that
  confirmed at or above `opens_at_height`, a roll that isn't sorted and unique,
  a ballot without a txid or with a bad height or position, the same txid
  twice, or two ballots at one height and position.
  """
  @spec count(map(), map(), [map()], keyword()) :: {:ok, result()} | {:error, input_error()}
  def count(election, roll, ballots, opts \\ []) do
    with :ok <- check_election(election),
         {:ok, members} <- check_roll(roll, election["opens_at_height"]),
         :ok <- check_ballots(ballots) do
      {:ok, do_count(election, members, ballots, Keyword.get(opts, :close_block_hash))}
    end
  end

  # -- Input checks ---------------------------------------------------------

  defp check_election(%{} = e) do
    candidates = e["candidates"]
    ids = if is_list(candidates), do: Enum.map(candidates, &(is_map(&1) && &1["id"])), else: []

    cond do
      not outpoint?(e["election"]) ->
        election_error(@e_id)

      not pos_integer?(e["number_elected"]) ->
        election_error(@e_number_elected)

      Map.has_key?(e, "votes_allowed") and not pos_integer?(e["votes_allowed"]) ->
        election_error(@e_votes_allowed)

      not is_list(candidates) or not Enum.all?(ids, &is_binary/1) ->
        election_error(@e_candidates)

      not Enum.all?(ids, &Regex.match?(@candidate_id, &1)) ->
        election_error(@e_candidate_id)

      length(Enum.uniq(ids)) != length(ids) ->
        election_error(@e_candidate_unique)

      not outpoint?(e["roll"]) ->
        election_error(@e_roll_outpoint)

      not (is_binary(e["roll_sha256"]) and Regex.match?(@sha256_hex, e["roll_sha256"])) ->
        election_error(@e_roll_sha256)

      not (height?(e["opens_at_height"]) and height?(e["closes_at_height"])) ->
        election_error(@e_heights)

      e["closes_at_height"] < e["opens_at_height"] ->
        election_error(@e_backwards)

      not confirms_before?(e, e["opens_at_height"]) ->
        election_error(@e_election_height)

      true ->
        :ok
    end
  end

  defp check_election(_), do: election_error(@e_not_map)

  defp election_error(detail), do: {:error, {:invalid_election, detail}}

  defp check_roll(%{"members" => members} = roll, opens_at_height) when is_list(members) do
    cond do
      not Enum.all?(members, &is_binary/1) -> roll_error(@r_strings)
      length(Enum.uniq(members)) != length(members) -> roll_error(@r_unique)
      Enum.sort(members) != members -> roll_error(@r_sorted)
      not confirms_before?(roll, opens_at_height) -> roll_error(@r_height)
      true -> {:ok, MapSet.new(members)}
    end
  end

  defp check_roll(_, _), do: roll_error(@r_not_map)

  defp roll_error(detail), do: {:error, {:invalid_roll, detail}}

  defp outpoint?(value), do: is_binary(value) and Regex.match?(@outpoint, value)
  defp pos_integer?(value), do: is_integer(value) and value > 0
  defp height?(value), do: is_integer(value) and value >= 0

  # A record's own height is optional; when given, it must be below the open.
  defp confirms_before?(record, opens_at_height) do
    case Map.fetch(record, "height") do
      :error -> true
      {:ok, nil} -> true
      {:ok, h} -> height?(h) and h < opens_at_height
    end
  end

  defp check_ballots(ballots) when is_list(ballots) do
    Enum.reduce_while(ballots, {MapSet.new(), MapSet.new()}, fn ballot, {txids, slots} ->
      case check_ballot(ballot) do
        :ok ->
          txid = ballot["txid"]
          slot = {ballot["height"], ballot["position"]}

          cond do
            MapSet.member?(txids, txid) ->
              {:halt, {:error, {:invalid_ballot, txid, @b_twice}}}

            ballot["height"] != nil and MapSet.member?(slots, slot) ->
              {:halt, {:error, {:invalid_ballot, txid, @b_slot}}}

            true ->
              {:cont, {MapSet.put(txids, txid), MapSet.put(slots, slot)}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp check_ballots(_), do: {:error, {:invalid_ballot, nil, @b_list}}

  defp check_ballot(%{"txid" => txid} = b) when is_binary(txid) do
    cond do
      b["height"] == nil -> :ok
      not height?(b["height"]) -> {:error, {:invalid_ballot, txid, @b_height}}
      not height?(b["position"]) -> {:error, {:invalid_ballot, txid, @b_position}}
      true -> :ok
    end
  end

  defp check_ballot(_), do: {:error, {:invalid_ballot, nil, @b_txid}}

  # -- The count ------------------------------------------------------------

  defp do_count(election, members, ballots, close_block_hash) do
    candidate_ids = Enum.map(election["candidates"], & &1["id"])
    known = MapSet.new(candidate_ids)
    votes_allowed = Map.get(election, "votes_allowed") || election["number_elected"]

    # Chain order: confirmed by (height, position), then unconfirmed by txid.
    ordered = Enum.sort_by(ballots, &order_key/1)

    judged =
      Enum.map(ordered, &{&1, first_failure(&1, election, votes_allowed, members, known)})

    # The latest passing ballot per signer, in chain order.
    latest =
      for {b, nil} <- judged, reduce: %{} do
        acc -> Map.put(acc, b["signer"], b["txid"])
      end

    results =
      Enum.map(judged, fn
        {%{"txid" => txid} = b, nil} ->
          case Map.fetch!(latest, b["signer"]) do
            ^txid -> %{txid: txid, counted: true, rule: nil, replaced_by: nil}
            later -> %{txid: txid, counted: false, rule: :replaced, replaced_by: later}
          end

        {b, rule} ->
          %{txid: b["txid"], counted: false, rule: rule, replaced_by: nil}
      end)

    counted_txids = for %{counted: true, txid: t} <- results, into: MapSet.new(), do: t

    votes =
      for {b, nil} <- judged,
          MapSet.member?(counted_txids, b["txid"]),
          choice <- b["choices"],
          reduce: Map.new(candidate_ids, &{&1, 0}) do
        acc -> Map.update!(acc, choice, &(&1 + 1))
      end

    tally = Enum.map(candidate_ids, &%{candidate: &1, votes: Map.fetch!(votes, &1)})
    {winners, undecided} = winners(tally, election["number_elected"], close_block_hash)
    counted = MapSet.size(counted_txids)

    %{
      election: election["election"],
      ballots: results,
      counted: counted,
      not_counted: length(results) - counted,
      tally: tally,
      winners: winners,
      undecided: undecided
    }
  end

  defp order_key(%{"height" => nil, "txid" => txid}), do: {1, 0, 0, txid}
  defp order_key(%{"height" => h, "position" => p, "txid" => txid}), do: {0, h, p, txid}

  defp first_failure(b, election, votes_allowed, members, known) do
    choices = b["choices"]

    cond do
      b["election"] != election["election"] -> :other_election
      not is_binary(b["signer"]) -> :no_signature
      not MapSet.member?(members, b["signer"]) -> :not_on_roll
      b["height"] == nil -> :unconfirmed
      b["height"] < election["opens_at_height"] -> :before_open
      b["height"] > election["closes_at_height"] -> :after_close
      not (is_list(choices) and Enum.all?(choices, &is_binary/1)) -> :malformed_choices
      length(choices) > votes_allowed -> :too_many_choices
      length(Enum.uniq(choices)) != length(choices) -> :duplicate_choice
      not Enum.all?(choices, &MapSet.member?(known, &1)) -> :unknown_candidate
      true -> nil
    end
  end

  # Groups candidates with votes by count, most first (sort_by is stable, so a
  # group keeps the election's order); fills seats group by group; a group
  # bigger than the seats left is settled by lot, or left undecided.
  defp winners(tally, seats, close_block_hash) do
    tally
    |> Enum.filter(&(&1.votes > 0))
    |> Enum.sort_by(& &1.votes, :desc)
    |> Enum.chunk_by(& &1.votes)
    |> Enum.reduce_while({[], nil}, fn group, {won, nil} ->
      left = seats - length(won)
      ids = Enum.map(group, & &1.candidate)

      cond do
        left == 0 ->
          {:halt, {won, nil}}

        length(ids) <= left ->
          {:cont, {won ++ ids, nil}}

        is_binary(close_block_hash) ->
          {:halt, {won ++ Enum.take(by_lot(ids, close_block_hash), left), nil}}

        true ->
          {:halt, {won, %{seats: left, tied: ids}}}
      end
    end)
  end

  defp by_lot(ids, close_block_hash) do
    hash = String.downcase(close_block_hash)
    Enum.sort_by(ids, &lot(hash, &1))
  end

  @doc """
  The lot for one candidate: `sha256("<close_block_hash>:<candidate id>")` as
  lowercase hex, the lowest winning a tied seat. `close_block_hash` is the
  block hash in RPC and display order (as explorers and `getblockhash` show
  it), the reverse of the header's internal byte order, as lowercase hex.
  """
  @spec lot(String.t(), String.t()) :: String.t()
  def lot(close_block_hash, candidate_id) do
    :crypto.hash(:sha256, String.downcase(close_block_hash) <> ":" <> candidate_id)
    |> Base.encode16(case: :lower)
  end
end
