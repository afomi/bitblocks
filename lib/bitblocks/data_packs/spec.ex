defmodule Bitblocks.DataPacks.Spec do
  @moduledoc false

  defstruct [
    :name,
    :network,
    :start_height,
    :end_height,
    :fidelity,
    :output_root,
    :block_chunk_size,
    :tx_chunk_size
  ]

  @type fidelity :: :headers_only | :index_only | :full

  @type t :: %__MODULE__{
          name: String.t(),
          network: String.t(),
          start_height: non_neg_integer(),
          end_height: non_neg_integer(),
          fidelity: fidelity(),
          output_root: String.t(),
          block_chunk_size: pos_integer(),
          tx_chunk_size: pos_integer()
        }

  @valid_fidelities ~w(headers_only index_only full)

  def build(opts) when is_list(opts) do
    with {:ok, start_height} <- fetch_non_negative_integer(opts, :start_height),
         {:ok, end_height} <- fetch_non_negative_integer(opts, :end_height),
         :ok <- validate_range(start_height, end_height),
         {:ok, fidelity} <- fetch_fidelity(opts),
         {:ok, output_root} <- fetch_string(opts, :output_root),
         {:ok, block_chunk_size} <- fetch_positive_integer(opts, :block_chunk_size, 25),
         {:ok, tx_chunk_size} <- fetch_positive_integer(opts, :tx_chunk_size, 100) do
      network = Keyword.get(opts, :network, "mainnet")
      name = Keyword.get(opts, :name, default_name(network, start_height, end_height, fidelity))

      {:ok,
       %__MODULE__{
         name: name,
         network: network,
         start_height: start_height,
         end_height: end_height,
         fidelity: fidelity,
         output_root: output_root,
         block_chunk_size: block_chunk_size,
         tx_chunk_size: tx_chunk_size
       }}
    end
  end

  def output_dir(%__MODULE__{output_root: output_root, name: name}) do
    Path.join(output_root, name)
  end

  def default_name(network, start_height, end_height, fidelity) do
    [
      network,
      pad_height(start_height),
      pad_height(end_height),
      Atom.to_string(fidelity)
    ]
    |> Enum.join("-")
  end

  defp fetch_fidelity(opts) do
    case Keyword.get(opts, :fidelity, "headers_only") do
      fidelity when fidelity in @valid_fidelities ->
        {:ok, String.to_existing_atom(fidelity)}

      fidelity when is_atom(fidelity) and fidelity in [:headers_only, :index_only, :full] ->
        {:ok, fidelity}

      other ->
        {:error,
         "invalid fidelity #{inspect(other)}. Expected one of: #{Enum.join(@valid_fidelities, ", ")}"}
    end
  end

  defp fetch_non_negative_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> parse_integer(key, value, min: 0)
      :error -> {:error, "missing required option --#{key_to_cli(key)}"}
    end
  end

  defp fetch_positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value ->
        parse_integer(key, value, min: 1)
    end
  end

  defp parse_integer(key, value, opts) do
    min = Keyword.fetch!(opts, :min)

    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= min -> {:ok, parsed}
      _ -> {:error, "invalid value for --#{key_to_cli(key)}: #{inspect(value)}"}
    end
  end

  defp fetch_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:ok, to_string(value)}
      :error -> {:error, "missing required option --#{key_to_cli(key)}"}
    end
  end

  defp validate_range(start_height, end_height) when start_height <= end_height, do: :ok
  defp validate_range(_start_height, _end_height), do: {:error, "--start-height must be <= --end-height"}

  defp key_to_cli(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp pad_height(height) do
    height
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
