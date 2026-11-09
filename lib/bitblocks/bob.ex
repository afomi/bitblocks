defmodule Bitblocks.Bob do
  @moduledoc """
  A transaction as BOB (Bitcoin OP_RETURN Bytecode), unwriter's shape for
  reading script data: every input and output is a list of tapes, and every
  tape a list of cells, one per script chunk.

  It follows BPU, the parser that produced BOB
  (https://github.com/interplanaria/bpu), with BOB's two split rules:
  `OP_RETURN` ends its tape (included on the left), and a `|` push stands as a
  tape of its own. Read from the tx's bytes on the fly; nothing is stored.

  A push is `%{b, s, h, i, ii}`: base64, UTF-8 (invalid bytes become U+FFFD,
  as Node's `toString('utf8')` does), hex, its index in the tape and its index
  in the whole script. `h` is ours; BPU gives `b` and `s`. An opcode is
  `%{op, ops, i, ii}`, named as bsv 1.x names it (`OP_0`, `OP_1`, `OP_NOP2`).

  Each input's `e` is `%{h, i, a}` (the outpoint it spends and, for a P2PKH
  unlock, the spending address) and carries `seq`; each output's `e` is
  `%{v, i, a}` (satoshis, index, and the P2PKH or P2SH address). Where there is
  no address, `a` is the string `"false"`, exactly as BPU writes it, so code
  written against BOB reads the same. `blk` is `%{i, h, t}` when the caller
  knows the block.
  """

  alias Bitblocks.{Chain, Repo, TxStore}
  alias Bitblocks.Chain.{Block, RawTx}

  @pipe "|"
  @max_bytes 4_000_000

  # bsv 1.x's names, where a byte has two: its reverse map keeps the last.
  @bsv1_names %{0 => "OP_0", 81 => "OP_1", 177 => "OP_NOP2", 178 => "OP_NOP3"}

  @ops for {atom, byte} <- BSV.OpCode.all(),
           into: %{},
           do: {atom, {byte, Map.get(@bsv1_names, byte, Atom.to_string(atom))}}

  @type cell :: map()
  @type tape :: %{cell: [cell()], i: non_neg_integer()}

  @doc """
  The BOB of a tx's bytes. `opts[:blk]` is `%{i: height, h: hash, t: time}`
  for a tx whose block is known. `{:error, :invalid_tx}` when the bytes
  aren't a tx.
  """
  @spec from_bytes(binary(), keyword()) :: {:ok, map()} | {:error, :invalid_tx}
  def from_bytes(bytes, opts \\ []) when is_binary(bytes) do
    case RawTx.parse(Base.encode16(bytes)) do
      {:ok, tx} -> {:ok, bob(tx, TxStore.txid(bytes), opts[:blk])}
      {:error, _} -> {:error, :invalid_tx}
    end
  end

  @doc """
  The BOB of a txid, from the bytes we hold or WhatsOnChain's
  (`TxStore.raw_or_fetch/1`). `blk` is set only when we store the tx and its
  block is the chain's (`Chain.confirmations/1` says `confirmed`).

  Refuses a tx over #{div(@max_bytes, 1_000_000)} MB with `{:error, :too_large}`,
  since its JSON would be several times that.
  """
  @spec for_txid(String.t()) ::
          {:ok, map()} | {:error, :not_found | :too_large | :invalid_tx | {:fetch_failed, term()}}
  def for_txid(txid) do
    with {:ok, bytes} <- TxStore.raw_or_fetch(txid),
         :ok <- if(byte_size(bytes) > @max_bytes, do: {:error, :too_large}, else: :ok) do
      from_bytes(bytes, blk: blk(txid))
    end
  end

  @doc "The largest tx, in bytes, `for_txid/1` gives BOB for."
  def max_bytes, do: @max_bytes

  defp blk(txid) do
    with %{block_hash: hash} = tx when is_binary(hash) <- Chain.get_transaction_by_txid(txid),
         %{^txid => %{confirmed: true}} <- Chain.confirmations([tx]),
         %Block{height: height, time: time} <- Repo.get_by(Block, hash: hash) do
      %{i: height, h: hash, t: time}
    else
      _ -> nil
    end
  end

  defp bob(%BSV.Tx{} = tx, txid, blk) do
    %{
      tx: %{h: txid},
      in: tx.inputs |> Enum.with_index() |> Enum.map(&input/1),
      out: tx.outputs |> Enum.with_index() |> Enum.map(&output/1),
      lock: tx.lock_time
    }
    |> then(fn bob -> if blk, do: Map.put(bob, :blk, blk), else: bob end)
  end

  defp input({%BSV.TxIn{outpoint: outpoint, script: script, sequence: seq}, index}) do
    %{
      i: index,
      tape: tapes(script.chunks),
      e: %{
        h: outpoint.hash |> reverse() |> Base.encode16(case: :lower),
        i: outpoint.vout,
        a: input_address(script.chunks)
      },
      seq: seq
    }
  end

  defp output({%BSV.TxOut{satoshis: satoshis, script: script}, index}) do
    %{
      i: index,
      tape: tapes(script.chunks),
      e: %{v: satoshis, i: index, a: output_address(script.chunks)}
    }
  end

  @doc """
  Splits a script's chunks into BOB tapes: `OP_RETURN` closes the tape it is
  in, and a `|` push is a tape by itself.
  """
  @spec tapes([atom() | binary()]) :: [tape()]
  def tapes(chunks) do
    {tapes, cell} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {chunk, ii}, {tapes, cell} ->
        item = item(chunk, ii, length(cell))

        cond do
          chunk == :OP_RETURN -> {[Enum.reverse([item | cell]) | tapes], []}
          chunk == @pipe -> {[[%{item | i: 0}] | close(cell, tapes)], []}
          true -> {tapes, [item | cell]}
        end
      end)

    close(cell, tapes)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {cell, i} -> %{cell: cell, i: i} end)
  end

  defp close([], tapes), do: tapes
  defp close(cell, tapes), do: [Enum.reverse(cell) | tapes]

  defp item(chunk, ii, i) when is_binary(chunk) do
    %{
      b: Base.encode64(chunk),
      s: String.replace_invalid(chunk),
      h: Base.encode16(chunk, case: :lower),
      i: i,
      ii: ii
    }
  end

  defp item(chunk, ii, i) when is_atom(chunk) do
    {op, ops} = Map.fetch!(@ops, chunk)
    %{op: op, ops: ops, i: i, ii: ii}
  end

  # bsv 1.x's `isPublicKeyHashIn`: a signature then a public key.
  defp input_address([sig, pubkey]) when is_binary(sig) and is_binary(pubkey) do
    if pubkey?(pubkey), do: pubkey |> hash160() |> address(0x00), else: "false"
  end

  defp input_address(_chunks), do: "false"

  defp output_address([:OP_DUP, :OP_HASH160, <<pkh::binary-20>>, :OP_EQUALVERIFY, :OP_CHECKSIG]),
    do: address(pkh, 0x00)

  defp output_address([:OP_HASH160, <<sh::binary-20>>, :OP_EQUAL]), do: address(sh, 0x05)
  defp output_address(_chunks), do: "false"

  defp pubkey?(<<prefix, _::binary-32>>) when prefix in [2, 3], do: true
  defp pubkey?(<<4, _::binary-64>>), do: true
  defp pubkey?(_bytes), do: false

  defp hash160(bytes), do: :crypto.hash(:ripemd160, :crypto.hash(:sha256, bytes))

  defp address(hash, version), do: B58.encode58_check!(hash, version)

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
