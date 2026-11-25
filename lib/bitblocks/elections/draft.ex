defmodule Bitblocks.Elections.Draft do
  @moduledoc """
  Reads the `/elections/new` form into an election and a roll in the shapes
  `Bitblocks.Elections.Count.count/4` takes, and checks them with the count's
  own rules, so the form can't build what the count would refuse.

  The form's text becomes values first (whole numbers, one candidate or
  address per line); then each part of the election is put to `Count.count/4`
  on its own, beside known-good values for the rest, so every part that
  breaks a rule is named at once, each refusal (`Count.refusals/0`) in plain
  words beside its field (`message/2`).

  `tip` is the height our headers reach. The records can confirm no sooner
  than `tip + 1`, so the count holds that below `opens_at_height`.

  Pure: no database, chain or clock.
  """

  alias Bitblocks.Elections.{Compose, Count}

  @placeholder String.duplicate("0", 64) <> ".0"

  # A week of blocks at ten minutes each.
  @week 1_008
  # Blocks between the tip and the open, for both records to confirm.
  @lead 6

  @fields ~w(name number_elected votes_allowed candidates members opens_at_height closes_at_height)

  @type t :: %{
          election: map(),
          roll: map(),
          members: [String.t()],
          repeated_members: non_neg_integer(),
          votes_allowed_given: boolean(),
          tip: integer() | nil
        }

  @type errors :: %{String.t() => [String.t()]}

  @doc "The form's fields, in page order."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "About a week, in blocks: 1,008 at ten minutes each."
  @spec week() :: pos_integer()
  def week, do: @week

  @doc "The blocks the suggested window leaves for the records to confirm."
  @spec lead() :: pos_integer()
  def lead, do: @lead

  @doc """
  A window of about a week from `tip`: opening #{@lead} blocks after it, so
  the roll and the election have about an hour to confirm, and closing
  #{@week} blocks later, both ends counting. Nil without a tip.
  """
  @spec week_window(integer() | nil) :: %{opens: integer(), closes: integer()} | nil
  def week_window(nil), do: nil

  def week_window(tip) when is_integer(tip) do
    opens = tip + @lead + 1
    %{opens: opens, closes: opens + @week - 1}
  end

  @doc """
  Reads and checks the form. Returns `{:ok, draft}` or `{:error, errors}`,
  errors being plain sentences by field.
  """
  @spec parse(map(), integer() | nil) :: {:ok, t()} | {:error, errors()}
  def parse(params, tip) do
    params = Map.new(@fields, &{&1, String.trim(to_string(params[&1] || ""))})

    {values, errors} =
      Enum.reduce(@fields, {%{}, %{}}, fn field, {values, errors} ->
        case read(field, params[field]) do
          {:ok, value} -> {Map.put(values, field, value), errors}
          {:error, message} -> {values, add(errors, field, message)}
        end
      end)

    errors = Map.merge(errors, count_errors(values, tip), fn _k, a, b -> a ++ b end)

    if errors == %{} do
      {:ok, draft(values, tip)}
    else
      {:error, errors}
    end
  end

  # -- Reading the text --------------------------------------------------------

  defp read("name", ""), do: {:error, "Give the election a name."}
  defp read("name", name), do: {:ok, name}

  defp read("number_elected", ""), do: {:error, "Enter how many seats are up."}
  defp read("number_elected", text), do: whole(text, "seats")

  defp read("votes_allowed", ""), do: {:ok, nil}
  defp read("votes_allowed", text), do: whole(text, "votes")

  defp read("opens_at_height", ""), do: {:error, "Enter the block voting opens at."}
  defp read("opens_at_height", text), do: whole(text, "a block height")

  defp read("closes_at_height", ""), do: {:error, "Enter the block voting closes at."}
  defp read("closes_at_height", text), do: whole(text, "a block height")

  defp read("candidates", text) do
    case lines(text) do
      [] -> {:error, "Add at least one candidate."}
      lines -> lines |> Enum.map(&candidate/1) |> all_ok()
    end
  end

  defp read("members", text) do
    case String.split(text, ~r/[\s,]+/, trim: true) do
      [] ->
        {:error, "Add at least one member's address."}

      addresses ->
        case Enum.reject(addresses, &p2pkh?/1) do
          [] ->
            {:ok, addresses}

          bad ->
            {:error, "These aren't P2PKH addresses (they start with 1): #{Enum.join(bad, ", ")}."}
        end
    end
  end

  defp whole(text, what) do
    text = String.replace(text, ~r/[,_ ]/, "")

    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "Enter #{what} as a whole number."}
    end
  end

  defp lines(text) do
    text |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # "id: Name", or "Name" alone, its id made from the name.
  defp candidate(line) do
    {id, name} =
      case String.split(line, ":", parts: 2) do
        [id, name] -> {String.trim(id), String.trim(name)}
        [name] -> {slug(name), name}
      end

    cond do
      name == "" -> {:error, "Give the candidate “#{id}” a name after the colon."}
      id == "" -> {:error, "Give “#{name}” an id, written as id: #{name}."}
      true -> {:ok, %{"id" => id, "name" => name}}
    end
  end

  defp all_ok(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
      error -> error
    end
  end

  @doc "A candidate id made from a name: lowercase a-z, 0-9, words joined by -."
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    name
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc "Whether `address` is a mainnet P2PKH address, as AIP writes a signer."
  @spec p2pkh?(String.t()) :: boolean()
  def p2pkh?(address) do
    match?({:ok, {<<_::binary-20>>, <<0x00>>}}, B58.decode58_check(address))
  rescue
    _ -> false
  end

  # -- The count's rules -------------------------------------------------------

  # Each part goes to the count alone, beside a known-good rest, so every part
  # that breaks a rule is named.
  @good %{
    "election" => @placeholder,
    "name" => "x",
    "number_elected" => 1,
    "candidates" => [%{"id" => "x", "name" => "x"}],
    "opens_at_height" => 1,
    "closes_at_height" => 1,
    "roll" => @placeholder,
    "roll_sha256" => String.duplicate("0", 64)
  }

  @parts [
    {"number_elected", ["number_elected"]},
    {"votes_allowed", ["votes_allowed"]},
    {"candidates", ["candidates"]},
    {"window", ["opens_at_height", "closes_at_height"]}
  ]

  defp count_errors(values, tip) do
    @parts
    |> Enum.filter(fn {_part, keys} -> Enum.all?(keys, &Map.has_key?(values, &1)) end)
    |> Enum.reject(fn {part, _} ->
      part == "votes_allowed" and is_nil(values["votes_allowed"])
    end)
    |> Enum.reduce(%{}, fn {_part, keys}, errors ->
      election = Map.merge(@good, Map.take(values, keys)) |> with_height(keys, tip)
      roll = %{"members" => []} |> with_height(keys, tip)

      case Count.count(election, roll, []) do
        {:ok, _} -> errors
        {:error, refusal} -> add(errors, field(refusal), message(refusal, tip))
      end
    end)
  end

  # The records confirm at tip + 1 at the soonest; only the window's check
  # needs that.
  defp with_height(record, ["opens_at_height" | _], tip) when is_integer(tip),
    do: Map.put(record, "height", tip + 1)

  defp with_height(record, _keys, _tip), do: record

  defp add(errors, field, message), do: Map.update(errors, field, [message], &(&1 ++ [message]))

  @doc """
  The field a count refusal belongs beside. `:form` for a refusal the form
  can't cause (an outpoint, a hash or a roll it builds itself).
  """
  @spec field({atom(), String.t()}) :: String.t() | :form
  def field({_kind, detail}) do
    case detail do
      "number_elected" <> _ -> "number_elected"
      "votes_allowed" <> _ -> "votes_allowed"
      "candidate" <> _ -> "candidates"
      "opens_at_height and closes_at_height" <> _ -> "opens_at_height"
      "closes_at_height is before" <> _ -> "closes_at_height"
      "the election record must confirm" <> _ -> "opens_at_height"
      "the roll must confirm" <> _ -> "opens_at_height"
      "members" <> _ -> "members"
      _ -> :form
    end
  end

  @doc """
  A count refusal in plain words, for the person filling in the form.
  `Count.refusals/0` lists every refusal; each has a sentence here.
  """
  @spec message({atom(), String.t()}, integer() | nil) :: String.t()
  def message({_kind, detail}, tip) do
    case detail do
      "number_elected" <> _ ->
        "Seats must be 1 or more."

      "votes_allowed" <> _ ->
        "Votes per member must be 1 or more."

      "candidates must be a list" <> _ ->
        "Each candidate needs an id."

      "candidate ids must be one or more" <> _ ->
        "Candidate ids use only lowercase letters a to z, digits 0 to 9 and hyphens."

      "candidate ids must be unique" <> _ ->
        "Two candidates have the same id; give each its own."

      "opens_at_height and closes_at_height" <> _ ->
        "Block heights are 0 or more."

      "closes_at_height is before" <> _ ->
        "Voting must close at or after the block it opens at."

      "the " <> _ when is_integer(tip) ->
        "Voting must open after block #{tip + 1}, so the roll and the election can confirm before the first ballot counts."

      "the " <> _ ->
        "Voting must open after the blocks the roll and the election confirm in."

      "members must be sorted" <> _ ->
        "The roll's addresses must be sorted."

      "members must be unique" <> _ ->
        "Each address goes on the roll once."

      "members must be strings" <> _ ->
        "Each member is an address."

      "roll must be the roll file's outpoint" <> _ ->
        "Enter the roll's outpoint as <txid>.<vout>."

      "roll must be a map" <> _ ->
        "The roll needs its members."

      "roll_sha256" <> _ ->
        "The roll's hash must be 64 lowercase hex characters."

      "election must be" <> _ ->
        "The election's id must be an outpoint, <txid>.<vout>."

      other ->
        other
    end
  end

  # -- The draft ---------------------------------------------------------------

  defp draft(values, tip) do
    members = values["members"] |> Enum.uniq() |> Enum.sort()
    content = Compose.roll_content(members)

    election =
      %{
        "name" => values["name"],
        "number_elected" => values["number_elected"],
        "votes_allowed" => values["votes_allowed"] || values["number_elected"],
        "candidates" => values["candidates"],
        "opens_at_height" => values["opens_at_height"],
        "closes_at_height" => values["closes_at_height"],
        "roll_sha256" => Compose.sha256(content)
      }

    %{
      election: election,
      roll: %{"members" => members},
      members: members,
      repeated_members: length(values["members"]) - length(members),
      votes_allowed_given: not is_nil(values["votes_allowed"]),
      tip: tip
    }
  end

  @doc """
  The election with its roll's outpoint, checked with the count once more as
  it will be published. `roll` is `<txid>.<vout>`, or a bare txid for output
  0, where the roll's createAction puts the record.
  """
  @spec with_roll(t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def with_roll(%{election: election, roll: roll} = draft, text) do
    text = text |> String.trim() |> String.downcase()
    outpoint = if Regex.match?(~r/\A[0-9a-f]{64}\z/, text), do: text <> ".0", else: text
    election = Map.merge(election, %{"roll" => outpoint, "election" => @placeholder})

    roll =
      if is_integer(draft.tip), do: Map.put(roll, "height", draft.tip + 1), else: roll

    election =
      if is_integer(draft.tip), do: Map.put(election, "height", draft.tip + 1), else: election

    case Count.count(election, roll, []) do
      {:ok, _} ->
        {:ok, election |> Map.drop(["election", "height"])}

      {:error, refusal} ->
        {:error, message(refusal, draft.tip)}
    end
  end
end
