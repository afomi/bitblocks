defmodule Bitblocks.Script do
  @moduledoc """
  Script-level analysis: classification, semantic field extraction, and the
  two content hashes that make arbitrary scripts queryable.

  This is the home of everything that looks at a `%BSV.Script{}` in isolation
  — extracted from `Bitblocks.TransactionParser` (which keeps delegating shims
  for its public API) so protocol handlers, the descriptor builder, and the
  API layer share one implementation.

  ## The two hashes

    * `script_hash/1` — SHA256 of the raw scriptPubKey bytes, byte-reversed
      hex (the Electrum/WhatsOnChain convention). Identifies one exact script,
      so any output — P2PKH or a custom covenant — is addressable even when no
      address can be derived.

    * `template_hash/1` — hash of the script's opcode skeleton with every
      push-data chunk collapsed to a placeholder. Two instances of the same
      contract template with different arguments (keys, hashes, amounts) share
      a template_hash, which is what makes "show me every use of this
      contract" possible (see `script_templates`).
  """

  alias BSV.Script

  @type script_type :: :p2pkh | :p2sh | :p2pk | :multisig | :op_return | :unknown

  @doc """
  Classifies a script into the known taxonomy, `:unknown` otherwise.
  """
  @spec classify(Script.t()) :: script_type()
  def classify(script) do
    case script.chunks do
      [:OP_RETURN | _] -> :op_return
      [:OP_FALSE, :OP_RETURN | _] -> :op_return
      [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG] when is_binary(pkh) -> :p2pkh
      [:OP_HASH160, sh, :OP_EQUAL] when is_binary(sh) -> :p2sh
      [pk, :OP_CHECKSIG] when is_binary(pk) and byte_size(pk) in [33, 65] -> :p2pk
      chunks -> if multisig?(chunks), do: :multisig, else: :unknown
    end
  end

  @doc """
  Extracts semantic fields from a script based on its type.

  Returns a map with type-specific fields:
    - `:p2pkh`    — `%{type: :p2pkh, pubkey_hash: hex}`
    - `:p2sh`     — `%{type: :p2sh, script_hash: hex}`
    - `:p2pk`     — `%{type: :p2pk, pubkey: hex}`
    - `:multisig` — `%{type: :multisig, m: integer, n: integer, pubkeys: [hex]}`
    - `:op_return`— `%{type: :op_return, data: [chunk_map]}`
    - `:unknown`  — `%{type: :unknown, asm: string}`
  """
  def extract_fields(script) do
    case classify(script) do
      :p2pkh ->
        [:OP_DUP, :OP_HASH160, pkh | _] = script.chunks
        %{type: :p2pkh, pubkey_hash: Base.encode16(pkh, case: :lower)}

      :p2sh ->
        [:OP_HASH160, sh | _] = script.chunks
        %{type: :p2sh, script_hash: Base.encode16(sh, case: :lower)}

      :p2pk ->
        [pk | _] = script.chunks
        %{type: :p2pk, pubkey: Base.encode16(pk, case: :lower)}

      :multisig ->
        [m_op | rest] = script.chunks
        pubkeys = rest |> Enum.filter(&is_binary/1)
        n = length(pubkeys)
        m = op_to_small_int(m_op)

        %{
          type: :multisig,
          m: m,
          n: n,
          pubkeys: Enum.map(pubkeys, &Base.encode16(&1, case: :lower))
        }

      :op_return ->
        %{type: :op_return, data: Bitblocks.Script.OpReturn.parse_data(script)}

      :unknown ->
        %{type: :unknown, asm: Script.to_asm(script)}
    end
  end

  @doc """
  SHA256 of the raw scriptPubKey bytes, byte-reversed, lowercase hex — the
  Electrum/WhatsOnChain scripthash convention, so results are directly
  comparable with those ecosystems' `/script/:scripthash/*` APIs.
  """
  def script_hash(%Script{} = script) do
    script
    |> Script.to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> reverse_bytes()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Electrum scripthash straight from a scriptPubKey hex string (as stored in
  the RPC output JSON) — no script decode needed. Returns nil on invalid hex.
  """
  def script_hash_from_hex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} ->
        bytes
        |> then(&:crypto.hash(:sha256, &1))
        |> reverse_bytes()
        |> Base.encode16(case: :lower)

      :error ->
        nil
    end
  end

  def script_hash_from_hex(_), do: nil

  @doc """
  Hash of the script's opcode skeleton: every push-data chunk collapsed to a
  `PUSH` placeholder (length-insensitive — template args vary in size), every
  opcode kept by name, joined and SHA256'd to lowercase hex.

  Two instances of the same contract template with different arguments share
  a template_hash.

  This is a cross-project id (qart's Holdings and the mobile pack manifest key
  UTXO types on it), so the canonical form is a contract: it does not depend
  on `script_analysis_version`, and golden vectors in `script_test.exs` fail if
  a BSV library upgrade changes opcode naming. Small-int opcodes (`OP_1`…)
  are structure, not `PUSH`.
  """
  def template_hash(%Script{} = script) do
    script.chunks
    |> Enum.map_join(" ", fn
      chunk when is_binary(chunk) -> "PUSH"
      opcode when is_atom(opcode) -> Atom.to_string(opcode)
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  True when the chunk list forms a valid bare m-of-n multisig script.
  """
  def multisig?(chunks) do
    case chunks do
      [m | rest] when is_atom(m) ->
        case op_to_small_int(m) do
          nil ->
            false

          m_val when m_val in 1..16 ->
            case List.last(chunks) do
              :OP_CHECKMULTISIG ->
                pubkeys = rest |> Enum.drop(-2) |> Enum.filter(&is_binary/1)
                n_op = Enum.at(rest, length(rest) - 2)
                n_val = op_to_small_int(n_op)
                n_val != nil and length(pubkeys) == n_val and m_val <= n_val

              _ ->
                false
            end
        end

      _ ->
        false
    end
  end

  @doc """
  Maps OP_TRUE/OP_1..OP_16 atoms to their integer values; nil otherwise.
  """
  def op_to_small_int(:OP_TRUE), do: 1
  def op_to_small_int(:OP_1), do: 1
  def op_to_small_int(:OP_2), do: 2
  def op_to_small_int(:OP_3), do: 3
  def op_to_small_int(:OP_4), do: 4
  def op_to_small_int(:OP_5), do: 5
  def op_to_small_int(:OP_6), do: 6
  def op_to_small_int(:OP_7), do: 7
  def op_to_small_int(:OP_8), do: 8
  def op_to_small_int(:OP_9), do: 9
  def op_to_small_int(:OP_10), do: 10
  def op_to_small_int(:OP_11), do: 11
  def op_to_small_int(:OP_12), do: 12
  def op_to_small_int(:OP_13), do: 13
  def op_to_small_int(:OP_14), do: 14
  def op_to_small_int(:OP_15), do: 15
  def op_to_small_int(:OP_16), do: 16
  def op_to_small_int(_), do: nil

  defp reverse_bytes(bin) when is_binary(bin) do
    bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end
end
