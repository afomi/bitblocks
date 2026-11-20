defmodule Bitblocks.Bitcom.BFile do
  @moduledoc """
  A B:// file in a tx: the first data output whose first push is the B prefix.

      OP_FALSE OP_RETURN 19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut <data> <media type> [encoding] [filename]

  Spec: https://b.bitdb.network. Later piped segments (MAP, AIP) are ignored.
  A file split with BCat is served by `/content/bcat/:txid`.
  """

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @pipe "|"

  @type t :: %{
          vout: non_neg_integer(),
          content: binary(),
          media_type: String.t() | nil,
          encoding: String.t() | nil,
          filename: String.t() | nil
        }

  @doc "The tx's B:// file, or `:error` when it has none."
  @spec parse(BSV.Tx.t()) :: {:ok, t()} | :error
  def parse(%BSV.Tx{outputs: outputs}) do
    outputs
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {output, vout} ->
      case segment(output.script.chunks) do
        [@b, content | rest] when is_binary(content) -> {:ok, file(content, rest, vout)}
        _ -> nil
      end
    end)
  end

  @doc """
  Every B:// file in the tx, one per data output that carries one, in
  output order: what the C:// index (`Bitblocks.CFiles`) records, since a
  tx may carry more than one file. `[]` when it has none.
  """
  @spec parse_all(BSV.Tx.t()) :: [t()]
  def parse_all(%BSV.Tx{outputs: outputs}) do
    for {output, vout} <- Enum.with_index(outputs),
        [@b, content | rest] when is_binary(content) <- [segment(output.script.chunks)],
        do: file(content, rest, vout)
  end

  @doc "The B:// file at output `vout`, or `:error` when that output holds none."
  @spec parse_output(BSV.Tx.t(), non_neg_integer()) :: {:ok, t()} | :error
  def parse_output(%BSV.Tx{outputs: outputs}, vout) do
    with %BSV.TxOut{script: script} <- Enum.at(outputs, vout),
         [@b, content | rest] when is_binary(content) <- segment(script.chunks) do
      {:ok, file(content, rest, vout)}
    else
      _ -> :error
    end
  end

  defp segment([:OP_RETURN | rest]), do: Enum.take_while(rest, &(&1 != @pipe))
  defp segment([:OP_FALSE, :OP_RETURN | rest]), do: Enum.take_while(rest, &(&1 != @pipe))
  defp segment(_chunks), do: []

  defp file(content, rest, vout) do
    [media_type, encoding, filename] =
      (rest ++ [nil, nil, nil])
      |> Enum.take(3)
      |> Enum.map(&text/1)

    %{
      vout: vout,
      content: content,
      media_type: media_type,
      encoding: encoding,
      filename: filename
    }
  end

  # A blank push (B allows a single space or null) means "not given".
  defp text(value) when is_binary(value) do
    trimmed = value |> String.replace(<<0>>, "") |> String.trim()
    if trimmed != "" and String.valid?(trimmed), do: trimmed
  end

  defp text(_value), do: nil
end
