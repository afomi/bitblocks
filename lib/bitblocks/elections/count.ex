defmodule Bitblocks.Elections.Count do
  @moduledoc """
  The election counting rule (`docs/ELECTION_DOGFOOD.md`), as a pure function.

  It takes the election record, the roll and every ballot seen, and says for
  each ballot whether it counted and, if not, the first rule it failed; then the
  tally per candidate and the winners. It reads no database, chain or clock, so
  the live page, the archive and a third-party recount get the same answer from
  the same input. The published vectors,
  `priv/data/interop/election_count_v1.json` (served at
  `/interop/elections/count/v1.json`), hold it to that.

  Inputs use string keys, as the records decode from JSON:

    * election: `"election"` (id), `"seats"`, `"candidates"` (each `"id"` and
      `"name"`), `"opens_at_height"`, `"closes_at_height"`.
    * roll: `"members"`, the signer keys (addresses) allowed to vote.
    * ballot: `"txid"`, `"election"`, `"height"` (nil while unconfirmed or after
      a reorg drops its block), `"position"` (its index in the block),
      `"signer"` (the key whose AIP signature checked, nil when none did) and
      `"choices"` (candidate ids).

  Each ballot meets the rules in this order, and the first one it fails is its
  `rule`:

    1. `other_election`: it names a different election.
    2. `no_signature`: no AIP signature checked.
    3. `not_on_roll`: its signer isn't on the roll.
    4. `unconfirmed`: it isn't in a block.
    5. `before_open` / `after_close`: its block is outside
       `opens_at_height..closes_at_height` (both ends count).
    6. `malformed_choices`: `choices` isn't a list of strings.
    7. `too_many_choices`: it names more than `seats` candidates.
    8. `duplicate_choice`: it names one candidate twice.
    9. `unknown_candidate`: it names an id not on the election's list.
    10. `replaced`: the same signer has a later ballot, in chain order
        (height, then position), that passed every rule above.

  A ballot that fails rules 1 to 9 never replaces another. An empty `choices`
  passes, votes for no one, and so withdraws the signer's earlier votes.

  Winners: candidates with at least one vote, most votes first, up to `seats`.
  When candidates tie for the last seats, the tie is settled by lot from the
  hash of the block at `closes_at_height` (`close_block_hash`, lowercase hex as
  explorers show it): the tied candidates are ordered by
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

  @doc "Every rule a ballot can fail, in the order they're applied."
  @spec rules() :: [rule()]
  def rules, do: @rules

  @doc """
  Counts `ballots` for `election` against `roll`.

  Options: `close_block_hash`, the hash of the block at `closes_at_height`,
  which settles a tie for the last seats.

  Returns `{:error, reason}` when the input itself is malformed: an election
  without a positive `seats` or with duplicate candidate ids, a window that
  closes before it opens, a ballot without a txid or with a bad height or
  position, the same txid twice, or two ballots at one height and position.
  """
  @spec count(map(), map(), [map()], keyword()) :: {:ok, result()} | {:error, input_error()}
  def count(election, roll, ballots, opts \\ []) do
    with :ok <- check_election(election),
         {:ok, members} <- check_roll(roll),
         :ok <- check_ballots(ballots) do
      {:ok, do_count(election, members, ballots, Keyword.get(opts, :close_block_hash))}
    end
  end

  # -- Input checks ---------------------------------------------------------

  defp check_election(%{} = e) do
    ids = Enum.map(List.wrap(e["candidates"]), &(is_map(&1) && &1["id"]))

    cond do
      not is_binary(e["election"]) ->
        {:error, {:invalid_election, "election must be a string id"}}

      not (is_integer(e["seats"]) and e["seats"] > 0) ->
        {:error, {:invalid_election, "seats must be a positive integer"}}

      not is_list(e["candidates"]) or not Enum.all?(ids, &is_binary/1) ->
        {:error, {:invalid_election, "each candidate needs a string id"}}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, {:invalid_election, "candidate ids must be unique"}}

      not (is_integer(e["opens_at_height"]) and is_integer(e["closes_at_height"])) ->
        {:error, {:invalid_election, "opens_at_height and closes_at_height must be integers"}}

      e["closes_at_height"] < e["opens_at_height"] ->
        {:error, {:invalid_election, "closes_at_height is before opens_at_height"}}

      true ->
        :ok
    end
  end

  defp check_election(_), do: {:error, {:invalid_election, "election must be a map"}}

  defp check_roll(%{"members" => members}) when is_list(members) do
    if Enum.all?(members, &is_binary/1),
      do: {:ok, MapSet.new(members)},
      else: {:error, {:invalid_roll, "members must be strings"}}
  end

  defp check_roll(_), do: {:error, {:invalid_roll, "roll must be a map with members"}}

  defp check_ballots(ballots) when is_list(ballots) do
    Enum.reduce_while(ballots, {MapSet.new(), MapSet.new()}, fn ballot, {txids, slots} ->
      case check_ballot(ballot) do
        :ok ->
          txid = ballot["txid"]
          slot = {ballot["height"], ballot["position"]}

          cond do
            MapSet.member?(txids, txid) ->
              {:halt, {:error, {:invalid_ballot, txid, "txid appears twice"}}}

            ballot["height"] != nil and MapSet.member?(slots, slot) ->
              {:halt,
               {:error, {:invalid_ballot, txid, "another ballot has this height and position"}}}

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

  defp check_ballots(_), do: {:error, {:invalid_ballot, nil, "ballots must be a list"}}

  defp check_ballot(%{"txid" => txid} = b) when is_binary(txid) do
    cond do
      b["height"] == nil ->
        :ok

      not (is_integer(b["height"]) and b["height"] >= 0) ->
        {:error, {:invalid_ballot, txid, "height must be a non-negative integer or null"}}

      not (is_integer(b["position"]) and b["position"] >= 0) ->
        {:error, {:invalid_ballot, txid, "a confirmed ballot needs a non-negative position"}}

      true ->
        :ok
    end
  end

  defp check_ballot(_), do: {:error, {:invalid_ballot, nil, "each ballot needs a string txid"}}

  # -- The count ------------------------------------------------------------

  defp do_count(election, members, ballots, close_block_hash) do
    candidate_ids = Enum.map(election["candidates"], & &1["id"])
    known = MapSet.new(candidate_ids)

    # Chain order: confirmed by (height, position), then unconfirmed by txid.
    ordered = Enum.sort_by(ballots, &order_key/1)

    judged = Enum.map(ordered, &{&1, first_failure(&1, election, members, known)})

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
    {winners, undecided} = winners(tally, election["seats"], close_block_hash)
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

  defp first_failure(b, election, members, known) do
    choices = b["choices"]

    cond do
      b["election"] != election["election"] -> :other_election
      not is_binary(b["signer"]) -> :no_signature
      not MapSet.member?(members, b["signer"]) -> :not_on_roll
      b["height"] == nil -> :unconfirmed
      b["height"] < election["opens_at_height"] -> :before_open
      b["height"] > election["closes_at_height"] -> :after_close
      not (is_list(choices) and Enum.all?(choices, &is_binary/1)) -> :malformed_choices
      length(choices) > election["seats"] -> :too_many_choices
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
  lowercase hex. The lowest wins a tied seat.
  """
  @spec lot(String.t(), String.t()) :: String.t()
  def lot(close_block_hash, candidate_id) do
    :crypto.hash(:sha256, String.downcase(close_block_hash) <> ":" <> candidate_id)
    |> Base.encode16(case: :lower)
  end
end
