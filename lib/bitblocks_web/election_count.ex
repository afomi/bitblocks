defmodule BitblocksWeb.ElectionCount do
  @moduledoc """
  The read-only election count for `/elections` and
  `GET /api/v1/elections/:outpoint`.

  Both call `Bitblocks.Elections.gather/2` and then `Bitblocks.Elections.count/1`,
  the same count the archive uses. Bitblocks never signs or sends a ballot.
  """

  alias Bitblocks.Elections
  alias Bitblocks.Elections.Records

  @txid ~r/\A[0-9a-f]{64}\z/

  @doc """
  The count for `outpoint`, or `{:error, status, message}` with the same
  sentence the page shows. Status is 400, 404 or 422. Never raises.
  """
  @spec load(term()) :: {:ok, map()} | {:error, 400 | 404 | 422, String.t()}
  def load(outpoint) when is_binary(outpoint) do
    with {:ok, gathered} <- Elections.gather(outpoint),
         {:ok, counted} <- Elections.count(gathered) do
      {:ok, present(gathered, counted)}
    else
      {:error, reason} -> {:error, http_status(reason), message(reason)}
    end
  end

  def load(_outpoint), do: {:error, 400, message(:invalid_outpoint)}

  @doc "The JSON body: `%{data: data, meta: meta}`."
  @spec api(map()) :: %{data: map(), meta: map()}
  def api(count) do
    %{
      data: %{
        election: count.election,
        name: count.name,
        number_elected: count.number_elected,
        votes_allowed: count.votes_allowed,
        opens_at_height: count.opens_at_height,
        closes_at_height: count.closes_at_height,
        candidates: count.candidates,
        ballots:
          Enum.map(
            count.ballots,
            &Map.take(&1, [:txid, :signer, :counted, :status, :replaced_by])
          ),
        counted: count.counted,
        not_counted: count.not_counted,
        final: count.final,
        current_to: count.current_to,
        undecided: count.undecided
      },
      meta: %{
        complete_through: count.coverage.complete_through,
        covered_through: count.coverage.covered_through,
        app: count.app
      }
    }
  end

  @doc "One sentence for a gather or count error. No stack trace."
  @spec message(term()) :: String.t()
  def message(:invalid_outpoint) do
    "An election is named <txid>.<vout>, lowercase hex and a decimal vout."
  end

  def message({:not_found, :election}) do
    "No election record at that outpoint in the blocks we hold."
  end

  def message({:not_found, :roll}) do
    "No roll record at the outpoint this election names, in the blocks we hold."
  end

  def message({:not_found, what}) do
    "Nothing named #{reason_text(what)} was found for this election in the blocks we hold."
  end

  def message({:not_a_record, kind, reason}) do
    "The #{kind} at that outpoint is not a record we can count: #{reason_text(reason)}."
  end

  def message(:election_unconfirmed) do
    "The election record is unconfirmed, so it is not counted."
  end

  def message(:roll_sha256_mismatch) do
    "The roll file does not match roll_sha256 on the election record."
  end

  def message(:roll_not_signed_by_administrator) do
    "The roll was not signed by the election's administrator."
  end

  def message({:too_many_candidates, max}) do
    "The scan passed its limit of #{max} rows (too_many_candidates), so this election is not counted."
  end

  def message({:proof_unavailable, txid, reason}) do
    "A merkle proof for #{txid} is unavailable (#{reason_text(reason)})."
  end

  def message({:bytes_mismatch, txid}) do
    "The stored bytes for #{txid} do not hash to that transaction."
  end

  def message({:raw_unavailable, txid}) do
    "The raw transaction #{txid} is not available to read."
  end

  def message(:projection_not_transactions) do
    "That projection does not read transactions, so its ballots cannot be counted."
  end

  def message({:invalid_election, detail}) do
    "This election record cannot be counted: #{detail}."
  end

  def message({:invalid_roll, detail}) do
    "This roll cannot be counted: #{detail}."
  end

  def message({:invalid_ballot, nil, detail}) do
    "A ballot cannot be counted: #{detail}."
  end

  def message({:invalid_ballot, txid, detail}) do
    "Ballot #{txid} cannot be counted: #{detail}."
  end

  def message(reason) do
    "This election cannot be counted (#{reason_text(reason)})."
  end

  @doc "How the page says a ballot came out."
  @spec ballot_status(map(), non_neg_integer()) :: String.t()
  def ballot_status(%{counted: true}, _closes), do: "Counted"

  def ballot_status(%{status: "not_on_roll"}, _closes) do
    "Not counted: this key isn't on the roll."
  end

  def ballot_status(%{status: "after_close"}, closes) do
    "Not counted: confirmed after block #{closes}."
  end

  def ballot_status(%{status: "replaced"}, _closes), do: "Replaced by a later ballot."

  def ballot_status(%{status: "unconfirmed"}, _closes), do: "Waiting for a block."

  def ballot_status(%{status: "no_signature"}, _closes) do
    "Not counted: no signature we could check."
  end

  def ballot_status(%{status: "before_open"}, _closes) do
    "Not counted: confirmed before voting opened."
  end

  def ballot_status(%{status: "other_election"}, _closes) do
    "Not counted: this ballot names a different election."
  end

  def ballot_status(%{status: "malformed_choices"}, _closes) do
    "Not counted: the choices are not a list of candidate ids."
  end

  def ballot_status(%{status: "too_many_choices"}, _closes) do
    "Not counted: more choices than this election allows."
  end

  def ballot_status(%{status: "duplicate_choice"}, _closes) do
    "Not counted: the same candidate is chosen twice."
  end

  def ballot_status(%{status: "unknown_candidate"}, _closes) do
    "Not counted: a choice is not a candidate in this election."
  end

  def ballot_status(%{status: status}, _closes), do: "Not counted: #{status}."

  @doc "Whether `value` is a transaction id we can link."
  @spec txid?(term()) :: boolean()
  def txid?(value) when is_binary(value), do: Regex.match?(@txid, value)
  def txid?(_value), do: false

  @doc "The sentence for a tie, or nil when every seat is settled."
  @spec undecided_sentence(nil | map()) :: String.t() | nil
  def undecided_sentence(nil), do: nil

  def undecided_sentence(%{tied: tied}) when is_list(tied) do
    "The remaining seats are tied: #{Enum.join(tied, ", ")}."
  end

  @doc "Whether the count is final, in a sentence."
  @spec final_sentence(boolean()) :: String.t()
  def final_sentence(true), do: "This count is final."
  def final_sentence(false), do: "This count is not final."

  @doc "How many votes, as a short phrase."
  @spec votes_label(non_neg_integer()) :: String.t()
  def votes_label(1), do: "1 vote"
  def votes_label(n) when is_integer(n), do: "#{n} votes"

  defp http_status(:invalid_outpoint), do: 400
  defp http_status({:not_found, _}), do: 404
  defp http_status(_reason), do: 422

  defp present(gathered, counted) do
    election = gathered.election_record.input
    tally = Map.new(counted.count.tally, &{&1.candidate, &1.votes})
    winners = MapSet.new(counted.count.winners)
    by_txid = Map.new(gathered.ballots, &{&1.txid, &1})

    %{
      election: gathered.election,
      name: election["name"],
      number_elected: election["number_elected"],
      votes_allowed: Map.get(election, "votes_allowed", election["number_elected"]),
      opens_at_height: election["opens_at_height"],
      closes_at_height: election["closes_at_height"],
      candidates: candidates(election["candidates"], tally, winners),
      ballots: ballots(counted.count.ballots, by_txid),
      counted: counted.count.counted,
      not_counted: counted.count.not_counted,
      final: counted.final,
      current_to: counted.current_to,
      undecided: counted.count.undecided,
      coverage: counted.coverage,
      election_txid: txid_of(gathered.election),
      roll_txid: txid_of(gathered.roll.outpoint),
      app: Records.app()
    }
  end

  defp candidates(list, tally, winners) do
    Enum.map(list, fn candidate ->
      id = candidate["id"]

      %{
        id: id,
        name: candidate["name"],
        votes: Map.get(tally, id, 0),
        elected: MapSet.member?(winners, id)
      }
    end)
  end

  defp ballots(results, by_txid) do
    Enum.map(results, fn result ->
      source = Map.get(by_txid, result.txid, %{})

      %{
        txid: result.txid,
        signer: Map.get(source, :signer),
        counted: result.counted,
        status: if(result.counted, do: "counted", else: Atom.to_string(result.rule)),
        replaced_by: result.replaced_by,
        choices: choices(source)
      }
    end)
  end

  defp choices(%{input: %{"choices" => choices}}) when is_list(choices), do: choices
  defp choices(_source), do: []

  defp txid_of(outpoint) do
    case Records.outpoint(outpoint) do
      {:ok, {txid, _vout}} -> txid
      :error -> nil
    end
  end

  defp reason_text(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.replace("_", " ")
  end

  defp reason_text({:wrong_type, other}), do: "it is a #{reason_text(other)} record"

  defp reason_text({:repeated_key, key}), do: "the key #{key} is repeated"

  defp reason_text({:unknown_type, nil}), do: "the type is missing"

  defp reason_text({:unknown_type, type}), do: "unknown type #{type}"

  defp reason_text({:missing_field, field}), do: "missing field #{field}"

  defp reason_text({:bad_field, field, detail}), do: "field #{field} is not valid (#{detail})"

  defp reason_text(other) do
    other
    |> inspect(limit: 5, printable_limit: 80)
    |> String.replace(~r/\s+/, " ")
  end
end
