defmodule Bitblocks.TxTypes.Classifier do
  @moduledoc """
  Types every output and every transaction against the definitions in
  `priv/data/tx_types/types.json` (afomi/bitblocks#49 phase 2).

  Pure and CPU-only: no database, no node. The pipeline runs it on every
  stored tx (`Chain.TxPipeline.Steps.ClassifyOutputs`).

  ## An output's type

  The first rule that matches, in this order:

    1. **Data** (`OP_RETURN …` or `OP_FALSE OP_RETURN …`): the protocol of
       its first segment (segments are split on `"|"` pushes), by the first
       push: `b`, `map`, `aip`, `sigma`, `metanet` (`"meta"` and a node
       key) or `run`; anything else is `op-return`.
    2. **Inscription** (an `OP_FALSE OP_IF "ord" … OP_ENDIF` envelope
       anywhere in the script): `bsv-21` or `bsv-20` when the body is a
       valid token operation (`Bitblocks.Bsv20Parser`); `inscription-map`
       when a MAP record follows an `OP_RETURN` after the envelope; else
       `1sat-inscription`.
    3. **Lock**: P2PKH holding exactly 1 sat is `1sat-output`, any other
       P2PKH is `p2pkh`; a public key and `OP_CHECKSIG` is `p2pk`;
       `OP_HASH160 <20 bytes> OP_EQUAL` is `p2sh`; the cosign shape is
       `cosign`; bare m-of-n is `multisig`; `OP_1` alone is
       `anyone-can-spend`; a STAS token's contract (`Bitblocks.Stas`) is
       `stas`; and a script whose
       template hash (`Bitblocks.Script.template_hash/1`) a type lists
       under `examples.template_hashes` is that type (`ordlock`,
       `timelock`).
    4. Anything else is `custom`.

  ## A transaction's type

  The set of its outputs' types, plus the known protocols of the later
  segments of its data outputs (a B file with a MAP record after the pipe
  is `b` and `map`; MAP signed by SIGMA is `map` and `sigma`), in the order
  of `types.json`. A MAP record whose `app` is `hodlocker.com` adds
  `hodlocker` (`Bitblocks.HodLocker`). A tx whose own lock time binds (it
  is nonzero and an input's sequence is below `0xffffffff`) adds
  `nlocktime` (`Bitblocks.NLockTime`), unless the lock time sits near the
  tip of the block it was mined in, as wallets set it against fee sniping;
  a nonzero lock time with every input final is ignored by the rules, so
  it adds nothing either. This one type needs the tx's block.

  Inputs matter in one place, kept simple: a Metanet node that names a
  parent is a node only when one of the tx's inputs is signed with a key
  (its unlocking script ends with a 33- or 65-byte public key push), since
  only the parent's key can add a child. Whether that key is the parent's
  is not checked here (it needs the parent tx); `Bitblocks.Metanet` reads
  the tree. Without such an input the output is `op-return`. A root names
  no parent and needs no signature.

  ## Version

  `version/0` is bumped whenever the type of any output or tx would change
  for the same bytes, including a change to the matching data in
  `types.json` (`vectors`, `examples.template_hashes`). The pipeline stamps
  it per row (`transactions.tx_types_version`, `docs/DERIVED_DATA.md`).
  """

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.{Bsv20Parser, NLockTime, TxTypes}

  # v2 (#49): P2PK and P2SH get their own types, so early coinbases stop
  # reading `custom`.
  # v3 (#78): STAS token outputs are `stas`, matched by their contract bytes.
  # v4 (#75): a tx with a HodLocker MAP record is also `hodlocker`.
  # v5 (#76): a tx whose nLockTime binds, and isn't the anti-fee-sniping
  # lock near its block's tip, is also `nlocktime`.
  # v6 (#78): STAS-20 outputs are `stas` too (a second STAS contract).
  @version 6

  @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  @aip "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"
  @pipe "|"

  # Types matched by their own rule in lock_type/2, not by template hash
  # (their listed hash covers one shape of many, or needs the value too).
  @own_rule ~w(p2pkh p2pk p2sh 1sat-output multisig cosign anyone-can-spend stas)

  # The other script shapes a type names by template hash.
  @by_template_hash for %{examples: %{kind: "template", template_hashes: hashes}, id: id} <-
                          TxTypes.all(),
                        id not in @own_rule,
                        hash <- hashes,
                        into: %{},
                        do: {hash, id}

  @order TxTypes.ids() |> Enum.with_index() |> Map.new()

  @type result :: %{outputs: [String.t()], types: [String.t()]}

  @doc "The classifier's version, stamped on each row it types."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The type id of one output: its locking script and its value in sats.
  Always an id from `types.json`; `"custom"` when nothing matches.
  """
  @spec output_type(BSV.Script.t(), non_neg_integer()) :: String.t()
  def output_type(%BSV.Script{chunks: chunks} = script, satoshis) do
    case data_segments(chunks) do
      {:data, [first | _]} -> segment_type(first) || "op-return"
      {:data, []} -> "op-return"
      :not_data -> inscription_type(chunks) || lock_type(script, satoshis) || "custom"
    end
  end

  @doc """
  Types a decoded tx: `outputs` holds each output's type in output order,
  and `types` the tx's type, a set of ids in `types.json` order.

  `block:` is the block the tx was mined in (its `height` and `time`),
  which the `nlocktime` type needs (`Bitblocks.NLockTime.typed?/2`):
  without it, that type is never given.
  """
  @spec classify(BSV.Tx.t(), keyword()) :: result()
  def classify(%BSV.Tx{inputs: inputs, outputs: outputs} = tx, opts \\ []) do
    signed? = Enum.any?(inputs, &signed_with_key?/1)

    {output_types, extra} =
      outputs
      |> Enum.map(&output(&1, signed?))
      |> Enum.unzip()

    types =
      (output_types ++ List.flatten(extra) ++ tx_level(tx, opts[:block]))
      |> Enum.uniq()
      |> Enum.sort_by(&Map.fetch!(@order, &1))

    %{outputs: output_types, types: types}
  end

  @doc """
  Decodes a raw tx (hex) and types it; `{:error, reason}` when it doesn't
  decode. Uses the tolerant `Chain.RawTx.parse/1`, which reads a script up to
  its first byte that isn't a whole opcode or push, so a tx whose data
  doesn't parse as script is still typed by the parts that do. Takes the
  same `block:` option as `classify/2`.
  """
  @spec classify_raw(String.t() | nil, keyword()) :: {:ok, result()} | {:error, term()}
  def classify_raw(raw, opts \\ [])

  def classify_raw(raw, opts) when is_binary(raw) do
    case RawTx.parse(raw) do
      {:ok, tx} -> {:ok, classify(tx, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  def classify_raw(_, _opts), do: {:error, :invalid_raw}

  # Types that belong to the tx itself, not to any one output.
  defp tx_level(tx, block), do: if(NLockTime.typed?(tx, block), do: ["nlocktime"], else: [])

  # An output's type, and the known protocols of its later data segments.
  defp output(%BSV.TxOut{script: %BSV.Script{chunks: chunks} = script, satoshis: sats}, signed?) do
    case data_segments(chunks) do
      {:data, [first | rest]} ->
        type =
          case segment_type(first) do
            "metanet" -> if metanet_node?(first, signed?), do: "metanet", else: "op-return"
            nil -> "op-return"
            type -> type
          end

        later = rest |> Enum.map(&segment_type/1) |> Enum.reject(&(&1 in [nil, "metanet"]))
        {type, later ++ if(Bitblocks.HodLocker.record?(chunks), do: ["hodlocker"], else: [])}

      _ ->
        {output_type(script, sats), []}
    end
  end

  # -- Data outputs ---------------------------------------------------------

  defp data_segments([:OP_RETURN | rest]), do: {:data, segments(rest)}
  defp data_segments([:OP_FALSE, :OP_RETURN | rest]), do: {:data, segments(rest)}
  defp data_segments(_), do: :not_data

  defp segments([]), do: []

  defp segments(chunks) do
    chunks
    |> Enum.chunk_by(&(&1 == @pipe))
    |> Enum.reject(&Enum.all?(&1, fn chunk -> chunk == @pipe end))
  end

  defp segment_type([@b | _]), do: "b"
  defp segment_type([@map | _]), do: "map"
  defp segment_type([@aip | _]), do: "aip"
  defp segment_type(["SIGMA" | _]), do: "sigma"
  defp segment_type(["run" | _]), do: "run"
  defp segment_type(["meta", p_node | _]) when is_binary(p_node) and p_node != "", do: "metanet"
  defp segment_type(_), do: nil

  # A root names no parent; a child needs an input signed with a key.
  defp metanet_node?(["meta", _p_node, parent | _], signed?) when is_binary(parent) do
    if parent?(parent), do: signed?, else: true
  end

  defp metanet_node?(["meta", _p_node | _], _signed?), do: true

  defp parent?(parent),
    do:
      parent != "" and parent != String.duplicate("0", 64) and
        parent != :binary.copy(<<0>>, byte_size(parent))

  defp signed_with_key?(%BSV.TxIn{script: %BSV.Script{chunks: [_ | _] = chunks}}) do
    case List.last(chunks) do
      <<prefix, _::binary-32>> when prefix in [2, 3] -> true
      <<4, _::binary-64>> -> true
      _ -> false
    end
  end

  defp signed_with_key?(_), do: false

  # -- Inscriptions ---------------------------------------------------------

  defp inscription_type(chunks) do
    case envelope(chunks) do
      nil ->
        nil

      after_envelope ->
        case Bsv20Parser.parse(chunks) do
          {:ok, %{standard: standard}} when standard in ["bsv-20", "bsv-21"] ->
            standard

          _ ->
            if map_tail?(after_envelope), do: "inscription-map", else: "1sat-inscription"
        end
    end
  end

  # The chunks after the envelope's OP_ENDIF, or nil when there is no envelope.
  defp envelope([marker, :OP_IF, "ord" | rest]) when marker in [:OP_FALSE, :OP_0] do
    case Enum.drop_while(rest, &(&1 != :OP_ENDIF)) do
      [:OP_ENDIF | after_envelope] -> after_envelope
      [] -> nil
    end
  end

  defp envelope([_ | rest]), do: envelope(rest)
  defp envelope([]), do: nil

  defp map_tail?(chunks) do
    case Enum.drop_while(chunks, &(&1 != :OP_RETURN)) do
      [:OP_RETURN, @map | _] -> true
      _ -> false
    end
  end

  # -- Locks ----------------------------------------------------------------

  defp lock_type(%BSV.Script{chunks: chunks} = script, satoshis) do
    case chunks do
      [:OP_DUP, :OP_HASH160, <<_::binary-20>>, :OP_EQUALVERIFY, :OP_CHECKSIG] ->
        if satoshis == 1, do: "1sat-output", else: "p2pkh"

      [pubkey, :OP_CHECKSIG] when is_binary(pubkey) and byte_size(pubkey) in [33, 65] ->
        "p2pk"

      [:OP_HASH160, <<_::binary-20>>, :OP_EQUAL] ->
        "p2sh"

      [
        :OP_DUP,
        :OP_HASH160,
        <<_::binary-20>>,
        :OP_EQUALVERIFY,
        :OP_CHECKSIGVERIFY,
        <<_::binary-33>>,
        :OP_CHECKSIG
      ] ->
        "cosign"

      [one] when one in [:OP_1, :OP_TRUE] ->
        "anyone-can-spend"

      chunks ->
        cond do
          Bitblocks.Script.multisig?(chunks) -> "multisig"
          Bitblocks.Stas.stas?(script) -> "stas"
          true -> Map.get(@by_template_hash, Bitblocks.Script.template_hash(script))
        end
    end
  end
end
