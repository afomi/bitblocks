defmodule Bitblocks.MetanetParser do
  @moduledoc """
  Parses Metanet node data from OP_RETURN scripts.

  A Metanet OP_RETURN has the structure:

      OP_RETURN "meta" <P_node> <TxID_parent> [<name>] [<content_type>] [<content>]

  Where:
  - `"meta"` is the 4-byte flag identifying this as a Metanet transaction
  - `P_node` is the 33-byte compressed public key of this node
  - `TxID_parent` is the 32-byte txid of the parent node (empty for root nodes)
  - Remaining fields are optional attributes and content
  """

  @metanet_flag "meta"

  @type metanet_node :: %{
          p_node: String.t(),
          parent_txid: String.t() | nil,
          is_root: boolean(),
          name: String.t() | nil,
          content_type: String.t() | nil,
          content: String.t() | nil,
          node_id: String.t() | nil
        }

  @doc """
  Parses Metanet node data from a list of parsed OP_RETURN data chunks.

  Chunks are in the format returned by `TransactionParser.parse_op_return_data/1`:
  `[%{type: :push_data, hex: "...", utf8: "...", length: N}, ...]`

  Returns `{:ok, metanet_node}` or `{:error, reason}`.
  """
  @spec parse(list(map())) :: {:ok, metanet_node()} | {:error, atom()}
  def parse(data_chunks) when is_list(data_chunks) do
    with :ok <- validate_flag(data_chunks),
         {:ok, p_node} <- extract_p_node(data_chunks),
         {:ok, parent_txid} <- extract_parent_txid(data_chunks) do
      name = extract_utf8_field(data_chunks, 3)
      content_type = extract_utf8_field(data_chunks, 4)
      content = extract_content(data_chunks, 5)

      {:ok,
       %{
         p_node: p_node,
         parent_txid: parent_txid,
         is_root: parent_txid == nil,
         name: name,
         content_type: content_type,
         content: content,
         node_id: nil
       }}
    end
  end

  def parse(_), do: {:error, :invalid_data}

  @doc """
  Parses a Metanet node from a transaction struct and computes the node ID.

  The transaction must have a non-nil `raw` field.
  """
  @spec parse_transaction(map()) :: {:ok, metanet_node()} | {:error, atom()}
  def parse_transaction(%{raw: nil}), do: {:error, :no_raw_data}

  def parse_transaction(%{raw: raw, txid: txid}) do
    case Bitblocks.Chain.SafeTx.from_hex(raw) do
      {:ok, tx} ->
        op_returns = Bitblocks.TransactionParser.extract_op_returns(tx.outputs)
        parse_from_op_returns(op_returns, txid)

      {:error, _} ->
        {:error, :invalid_raw}
    end
  end

  @doc """
  Computes the Metanet node ID: SHA256(P_node_bytes || TxID_bytes).

  Both inputs are hex strings. Returns a hex-encoded SHA256 hash.
  """
  @spec node_id(String.t(), String.t()) :: String.t()
  def node_id(p_node_hex, txid) when is_binary(p_node_hex) and is_binary(txid) do
    with {:ok, p_bytes} <- Base.decode16(p_node_hex, case: :mixed),
         {:ok, txid_bytes} <- Base.decode16(txid, case: :mixed) do
      :crypto.hash(:sha256, p_bytes <> txid_bytes)
      |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  # -- Private ----------------------------------------------------------------

  defp parse_from_op_returns([], _txid), do: {:error, :no_metanet_data}

  defp parse_from_op_returns(op_returns, txid) do
    Enum.find_value(op_returns, {:error, :no_metanet_data}, fn op_return ->
      case parse(op_return.data) do
        {:ok, node} ->
          nid = node_id(node.p_node, txid)
          {:ok, %{node | node_id: nid}}

        {:error, _} ->
          nil
      end
    end)
  end

  defp validate_flag(chunks) do
    case Enum.at(chunks, 0) do
      %{utf8: @metanet_flag} -> :ok
      %{hex: "6d657461"} -> :ok
      _ -> {:error, :not_metanet}
    end
  end

  # P_node is a 33-byte compressed public key (66 hex chars)
  defp extract_p_node(chunks) do
    case Enum.at(chunks, 1) do
      %{hex: hex} when is_binary(hex) and byte_size(hex) == 66 ->
        {:ok, hex}

      %{hex: hex} when is_binary(hex) and byte_size(hex) > 0 ->
        # Accept non-standard lengths but still treat as pubkey
        {:ok, hex}

      _ ->
        {:error, :missing_pubkey}
    end
  end

  @null_parent_txid String.duplicate("00", 32)

  # TxID_parent is a 32-byte txid (64 hex chars), or empty for root nodes
  defp extract_parent_txid(chunks) do
    case Enum.at(chunks, 2) do
      nil ->
        {:ok, nil}

      %{hex: hex} when hex == "" or hex == @null_parent_txid ->
        {:ok, nil}

      %{length: 0} ->
        {:ok, nil}

      %{hex: hex} when is_binary(hex) ->
        {:ok, hex}

      _ ->
        {:ok, nil}
    end
  end

  defp extract_utf8_field(chunks, index) do
    case Enum.at(chunks, index) do
      %{utf8: utf8} when is_binary(utf8) -> utf8
      _ -> nil
    end
  end

  defp extract_content(chunks, start_index) do
    chunks
    |> Enum.drop(start_index)
    |> Enum.map(fn
      %{utf8: utf8} when is_binary(utf8) -> utf8
      %{hex: hex} when is_binary(hex) -> hex
      _ -> ""
    end)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "")
    end
  end
end
