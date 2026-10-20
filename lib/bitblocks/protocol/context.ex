defmodule Bitblocks.Protocol.Context do
  @moduledoc """
  Pre-computed views of one OP_RETURN output's data, built once and shared by
  every handler's `detect/1` — so detection stays cheap on the sync hot path
  (no per-handler re-parsing, no DB access).

  `first_input_address` is the P2PKH address that spent the tx's first input
  (nil when unknown or not P2PKH). Bitcom ties a protocol prefix to an address,
  and a tx spent from that address is how its owner proves control of it.
  """

  alias Bitblocks.Script.OpReturn

  @type t :: %__MODULE__{
          data_chunks: list(map()),
          utf8_chunks: list(String.t()),
          segments: list(list(String.t())),
          hex_joined: String.t(),
          first_input_address: String.t() | nil
        }

  defstruct data_chunks: [],
            utf8_chunks: [],
            segments: [],
            hex_joined: "",
            first_input_address: nil

  @doc """
  Builds a context from parsed OP_RETURN chunk maps
  (`Bitblocks.Script.OpReturn.parse_data/1` output).
  """
  def build(data_chunks, opts \\ []) when is_list(data_chunks) do
    utf8_chunks = OpReturn.utf8_chunks(data_chunks)

    %__MODULE__{
      first_input_address: Keyword.get(opts, :first_input_address),
      data_chunks: data_chunks,
      utf8_chunks: utf8_chunks,
      segments: OpReturn.pipe_segments(utf8_chunks),
      hex_joined:
        Enum.map_join(data_chunks, fn
          %{hex: hex} -> hex
          _ -> ""
        end)
    }
  end

  @doc """
  The P2PKH address that spent `tx`'s first input, or nil.

  Read from the unlocking script (`<sig> <pubkey>`): the pubkey hashes to the
  spending address. Coinbase and non-P2PKH inputs give nil.
  """
  @spec first_input_address(BSV.Tx.t()) :: String.t() | nil
  def first_input_address(%BSV.Tx{inputs: [%BSV.TxIn{script: %BSV.Script{chunks: chunks}} | _]}) do
    case chunks do
      [sig, pubkey] when is_binary(sig) and is_binary(pubkey) and byte_size(pubkey) in [33, 65] ->
        pubkey |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def first_input_address(_tx), do: nil
end
