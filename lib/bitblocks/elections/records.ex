defmodule Bitblocks.Elections.Records do
  @moduledoc """
  Reads election records from a tx's bytes (`docs/ELECTION_DOGFOOD.md`,
  "Records"), into the shapes `Bitblocks.Elections.Count.count/4` takes.

  Every record is one data output: an optional B:// file, then a MAP `SET`,
  then an AIP signature, each segment apart by `|`:

      OP_FALSE OP_RETURN
        [19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut <file> <media type> <encoding> <filename> |]
        1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5 SET app <app> type <type> <key> <value> … |
        15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva BITCOIN_ECDSA <address> <signature> [<field index>…]

  The four types are `roll_v1` (the B:// file is the roll), `election_v1`,
  `ballot_v1` and `result_v1`. `app` is `app/0`, from config.

  A signature counts only when it checks and covers every field of the B and
  MAP segments, as `docs/BAP.md` requires: an AIP over chosen field indexes
  that leaves one out counts for nothing. The signer is the address as the AIP
  section writes it.

  An election, roll or result needs that signature, or it is no record. A
  ballot without one is still a ballot, with `"signer" => nil`, so the count
  lists it against `no_signature`; `signature_error` says why.

  Parsing is strict about encoding (one value per key, integers as decimal
  ASCII with no leading zeros, lists as one JSON array) and leaves the rules
  of the election (candidate ids, a sorted roll, the window) to the count,
  which refuses those with its own reasons. Total: anything unexpected is
  `{:error, reason}`, never a raise.
  """

  alias Bitblocks.Aip
  alias Bitblocks.Chain.RawTx

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  @pipe "|"

  @default_app "pba-election"

  @types %{
    "election_v1" => :election,
    "roll_v1" => :roll,
    "ballot_v1" => :ballot,
    "result_v1" => :result
  }

  @integer ~r/\A(0|[1-9][0-9]*)\z/
  @outpoint ~r/\A[0-9a-f]{64}\.(0|[1-9][0-9]*)\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @type kind :: :election | :roll | :ballot | :result

  @type record :: %{
          kind: kind(),
          vout: non_neg_integer(),
          signer: String.t() | nil,
          signature_error: atom() | nil,
          fields: %{String.t() => term()}
        }

  @type reason ::
          :invalid_tx
          | :no_output
          | :not_data
          | :no_map
          | :map_not_set
          | {:repeated_key, String.t()}
          | :odd_map_pairs
          | :other_app
          | {:unknown_type, String.t() | nil}
          | {:missing_field, String.t()}
          | {:bad_field, String.t(), String.t()}
          | :no_roll_file
          | :no_signature
          | :invalid_signature
          | :signature_does_not_cover_fields

  @doc """
  The `app` value records carry. Pending one name for the format; it is one
  line in `config/config.exs` (`config :bitblocks, :election_app`).
  """
  @spec app() :: String.t()
  def app, do: Application.get_env(:bitblocks, :election_app, @default_app)

  @doc "The record types, as their `type` value and kind."
  @spec types() :: %{String.t() => kind()}
  def types, do: @types

  @doc """
  Every election record in a tx (raw bytes), with its output index, in output
  order. Outputs that hold no record of this app are left out.
  """
  @spec parse_tx(binary()) :: {:ok, [record()]} | {:error, :invalid_tx}
  def parse_tx(bytes) when is_binary(bytes) do
    with {:ok, tx} <- decode(bytes) do
      records =
        tx.outputs
        |> Enum.with_index()
        |> Enum.flat_map(fn {output, vout} ->
          case parse_script(output.script, vout) do
            {:ok, record} -> [record]
            {:error, _} -> []
          end
        end)

      {:ok, records}
    end
  end

  @doc """
  The record at output `vout` of a tx (raw bytes), or `{:error, reason}`
  saying why that output isn't one.
  """
  @spec parse_output(binary(), non_neg_integer()) :: {:ok, record()} | {:error, reason()}
  def parse_output(bytes, vout) when is_binary(bytes) and is_integer(vout) and vout >= 0 do
    with {:ok, tx} <- decode(bytes),
         %BSV.TxOut{script: script} <- Enum.at(tx.outputs, vout) || {:error, :no_output} do
      parse_script(script, vout)
    end
  end

  @doc """
  Splits an outpoint `<txid>.<vout>` (lowercase hex, decimal vout with no
  leading zeros) into `{txid, vout}`.
  """
  @spec outpoint(term()) :: {:ok, {String.t(), non_neg_integer()}} | :error
  def outpoint(value) when is_binary(value) do
    if Regex.match?(@outpoint, value) do
      [txid, vout] = String.split(value, ".")
      {:ok, {txid, String.to_integer(vout)}}
    else
      :error
    end
  end

  def outpoint(_), do: :error

  # -- One output -------------------------------------------------------------

  defp decode(bytes) do
    case RawTx.parse(Base.encode16(bytes, case: :lower)) do
      {:ok, tx} -> {:ok, tx}
      {:error, _} -> {:error, :invalid_tx}
    end
  end

  defp parse_script(%BSV.Script{chunks: chunks}, vout) do
    with {:ok, data} <- data(chunks),
         segments = segments(data),
         {:ok, map_segment} <- map_segment(segments),
         {:ok, keys} <- map_keys(map_segment.cells),
         :ok <- same_app(keys),
         {:ok, kind} <- kind(keys),
         {signer, signature_error} <- signer(data, segments),
         :ok <- signature_needed(kind, signer, signature_error),
         {:ok, fields} <- fields(kind, keys, segments) do
      {:ok,
       %{
         kind: kind,
         vout: vout,
         signer: signer,
         signature_error: signature_error,
         fields: fields
       }}
    end
  end

  defp parse_script(_script, _vout), do: {:error, :not_data}

  # The pushes after OP_RETURN.
  defp data(chunks) do
    case Enum.drop_while(chunks, &(&1 != :OP_RETURN)) do
      [:OP_RETURN | data] -> {:ok, data}
      _ -> {:error, :not_data}
    end
  end

  # Each segment with its data positions, split on "|".
  defp segments(data) do
    {segments, current} =
      data
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn
        {@pipe, _i}, {done, current} -> {[Enum.reverse(current) | done], []}
        {cell, i}, {done, current} -> {done, [{cell, i} | current]}
      end)

    [Enum.reverse(current) | segments]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn [{prefix, _first} | _] = cells ->
      %{
        prefix: prefix,
        cells: Enum.map(cells, &elem(&1, 0)),
        positions: Enum.map(cells, &elem(&1, 1))
      }
    end)
  end

  defp map_segment(segments) do
    case Enum.find(segments, &(&1.prefix == @map)) do
      nil -> {:error, :no_map}
      segment -> {:ok, segment}
    end
  end

  defp map_keys([@map, "SET" | pairs]) do
    if rem(length(pairs), 2) == 1 or not Enum.all?(pairs, &is_binary/1) do
      {:error, :odd_map_pairs}
    else
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, %{}}, fn [key, value], {:ok, acc} ->
        if Map.has_key?(acc, key),
          do: {:halt, {:error, {:repeated_key, key}}},
          else: {:cont, {:ok, Map.put(acc, key, value)}}
      end)
    end
  end

  defp map_keys(_cells), do: {:error, :map_not_set}

  defp same_app(%{"app" => app}), do: if(app == app(), do: :ok, else: {:error, :other_app})
  defp same_app(_keys), do: {:error, :other_app}

  defp kind(%{"type" => type}) do
    case Map.fetch(@types, type) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  defp kind(_keys), do: {:error, {:unknown_type, nil}}

  # The first AIP signature that checks and covers every field of the B and
  # MAP segments. AIP numbers fields from 0 (OP_RETURN), so data position p
  # is field p + 1.
  defp signer(data, segments) do
    covered =
      segments
      |> Enum.filter(&(&1.prefix in [@b, @map]))
      |> Enum.flat_map(& &1.positions)
      |> Enum.map(&(&1 + 1))

    case Aip.signatures([:OP_RETURN | data]) do
      [] ->
        {nil, :no_signature}

      signatures ->
        valid = Enum.filter(signatures, &(&1.valid and is_binary(&1.address)))

        covering =
          Enum.find(valid, fn %{field_indexes: indexes} ->
            is_nil(indexes) or Enum.all?(covered, &(&1 in indexes))
          end)

        cond do
          covering -> {covering.address, nil}
          valid != [] -> {nil, :signature_does_not_cover_fields}
          true -> {nil, :invalid_signature}
        end
    end
  end

  # A ballot without a signature is still a ballot (the count lists it as
  # no_signature); the administrator's records need one.
  defp signature_needed(:ballot, _signer, _error), do: :ok
  defp signature_needed(_kind, signer, _error) when is_binary(signer), do: :ok
  defp signature_needed(_kind, nil, error), do: {:error, error}

  # -- Fields per type --------------------------------------------------------

  defp fields(:election, keys, _segments) do
    with {:ok, name} <- text(keys, "name"),
         {:ok, number_elected} <- integer(keys, "number_elected"),
         {:ok, votes_allowed} <- optional_integer(keys, "votes_allowed"),
         {:ok, candidates} <- json_list(keys, "candidates"),
         {:ok, opens} <- integer(keys, "opens_at_height"),
         {:ok, closes} <- integer(keys, "closes_at_height"),
         {:ok, roll} <- outpoint_field(keys, "roll"),
         {:ok, roll_sha256} <- hex64(keys, "roll_sha256") do
      fields = %{
        "name" => name,
        "number_elected" => number_elected,
        "candidates" => candidates,
        "opens_at_height" => opens,
        "closes_at_height" => closes,
        "roll" => roll,
        "roll_sha256" => roll_sha256
      }

      {:ok, if(votes_allowed, do: Map.put(fields, "votes_allowed", votes_allowed), else: fields)}
    end
  end

  defp fields(:roll, _keys, segments) do
    with {:ok, content} <- roll_file(segments),
         {:ok, members} <- members(content) do
      {:ok,
       %{
         "members" => members,
         "content" => content,
         "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
       }}
    end
  end

  defp fields(:ballot, keys, _segments) do
    with {:ok, election} <- outpoint_field(keys, "election") do
      # Choices that are missing or don't decode stay visible: the count
      # lists the ballot as malformed_choices, rather than the parser hiding it.
      choices =
        case Map.get(keys, "choices") do
          raw when is_binary(raw) ->
            case Jason.decode(raw) do
              {:ok, decoded} -> decoded
              {:error, _} -> raw
            end

          nil ->
            nil
        end

      {:ok, %{"election" => election, "choices" => choices}}
    end
  end

  defp fields(:result, keys, _segments) do
    with {:ok, election} <- outpoint_field(keys, "election"),
         {:ok, archive_sha256} <- hex64(keys, "archive_sha256"),
         {:ok, closes} <- integer(keys, "closes_at_height"),
         {:ok, close_block_hash} <- hex64(keys, "close_block_hash") do
      {:ok,
       %{
         "election" => election,
         "archive_sha256" => archive_sha256,
         "closes_at_height" => closes,
         "close_block_hash" => close_block_hash
       }}
    end
  end

  defp roll_file(segments) do
    case Enum.find(segments, &(&1.prefix == @b)) do
      %{cells: [@b, content | _]} when is_binary(content) -> {:ok, content}
      _ -> {:error, :no_roll_file}
    end
  end

  defp members(content) do
    case Jason.decode(content) do
      {:ok, %{"members" => members}} when is_list(members) -> {:ok, members}
      _ -> {:error, {:bad_field, "members", "the roll file must be JSON {\"members\": [...]}"}}
    end
  end

  defp text(keys, key) do
    case Map.fetch(keys, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value), do: {:ok, value}, else: {:error, {:bad_field, key, "not UTF-8"}}

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp integer(keys, key) do
    with {:ok, value} <- text(keys, key) do
      if Regex.match?(@integer, value),
        do: {:ok, String.to_integer(value)},
        else: {:error, {:bad_field, key, "decimal ASCII with no leading zeros"}}
    end
  end

  defp optional_integer(keys, key) do
    if Map.has_key?(keys, key), do: integer(keys, key), else: {:ok, nil}
  end

  defp json_list(keys, key) do
    with {:ok, value} <- text(keys, key) do
      case Jason.decode(value) do
        {:ok, list} when is_list(list) -> {:ok, list}
        _ -> {:error, {:bad_field, key, "one JSON array"}}
      end
    end
  end

  defp outpoint_field(keys, key) do
    with {:ok, value} <- text(keys, key) do
      case outpoint(value) do
        {:ok, _} -> {:ok, value}
        :error -> {:error, {:bad_field, key, "an outpoint: <txid>.<vout>"}}
      end
    end
  end

  defp hex64(keys, key) do
    with {:ok, value} <- text(keys, key) do
      if Regex.match?(@hex64, value),
        do: {:ok, value},
        else: {:error, {:bad_field, key, "64 lowercase hex characters"}}
    end
  end
end
