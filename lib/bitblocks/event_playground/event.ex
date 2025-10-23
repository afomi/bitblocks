defmodule Bitblocks.EventPlayground.Event do
  @moduledoc """
  Lightweight struct describing a simulated Bitcoin event in the playground.
  """

  @enforce_keys [
    :address,
    :event_number,
    :event_type,
    :object_id,
    :payload,
    :schema,
    :timestamp,
    :txid
  ]
  defstruct [
    :address,
    :event_number,
    :event_type,
    :object_id,
    :payload,
    :schema,
    :metadata,
    :timestamp,
    :txid
  ]

  @type t :: %__MODULE__{
          address: String.t(),
          event_number: pos_integer(),
          event_type: String.t(),
          object_id: String.t(),
          payload: map(),
          schema: String.t(),
          metadata: map() | nil,
          timestamp: DateTime.t(),
          txid: String.t()
        }

  @spec build(String.t(), map(), pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def build(address, attrs, event_number) when is_binary(address) and is_integer(event_number) do
    normalized_attrs = Map.new(attrs)

    with {:ok, object_id} <- fetch_required(normalized_attrs, :object_id),
         {:ok, event_type} <- fetch_required(normalized_attrs, :event_type),
         {:ok, schema} <- fetch_schema(normalized_attrs),
         {:ok, payload} <- fetch_payload(normalized_attrs) do
      {:ok,
       %__MODULE__{
         address: address,
         event_number: event_number,
         event_type: event_type,
         object_id: object_id,
         payload: payload,
         schema: schema,
         metadata: fetch_metadata(normalized_attrs),
         timestamp: fetch_timestamp(normalized_attrs),
         txid: fetch_txid(normalized_attrs)
       }}
    end
  end

  defp fetch_required(map, key) do
    case get_attr(map, key) do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _ ->
        {:error, "missing #{key}"}
    end
  end

  defp fetch_schema(map) do
    case get_attr(map, :schema, "com.bitblocks.note/v1") do
      schema when is_binary(schema) and schema != "" ->
        {:ok, String.trim(schema)}

      _ ->
        {:error, "missing schema"}
    end
  end

  defp fetch_payload(map) do
    case get_attr(map, :payload) do
      payload when is_map(payload) ->
        {:ok, stringify_map(payload)}

      nil ->
        {:error, "missing payload"}

      other when is_binary(other) ->
        case Jason.decode(other) do
          {:ok, decoded} when is_map(decoded) -> {:ok, stringify_map(decoded)}
          _ -> {:error, "payload must be JSON object"}
        end

      _ ->
        {:error, "payload must be map"}
    end
  end

  defp fetch_metadata(map) do
    case get_attr(map, :metadata) do
      metadata when is_map(metadata) ->
        stringify_map(metadata)

      metadata when metadata in [nil, ""] ->
        %{}

      metadata when is_binary(metadata) ->
        metadata
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.reduce(%{}, fn
          [key, value], acc -> Map.put(acc, String.trim(key), String.trim(value))
          _, acc -> acc
        end)

      _ ->
        %{}
    end
  end

  defp fetch_timestamp(map) do
    case get_attr(map, :timestamp) do
      %DateTime{} = ts ->
        ts

      %NaiveDateTime{} = ts ->
        DateTime.from_naive!(ts, "Etc/UTC")

      binary when is_binary(binary) and binary != "" ->
        case DateTime.from_iso8601(binary) do
          {:ok, dt, _offset} -> dt
          _ -> DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

  defp fetch_txid(map) do
    case get_attr(map, :txid) do
      txid when is_binary(txid) and txid != "" -> String.trim(txid)
      _ -> generate_txid()
    end
  end

  defp get_attr(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp stringify_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, stringify_key(key), value)
    end)
  end

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(other), do: to_string(other)

  defp generate_txid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
