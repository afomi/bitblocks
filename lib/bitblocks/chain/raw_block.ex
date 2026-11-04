defmodule Bitblocks.Chain.RawBlock do
  @moduledoc """
  A whole block fetched once as raw bytes and split into its transactions
  locally, so a block costs the node one request instead of a txid list plus
  a `getrawtransaction` batch per hundred txs.

  ## Sources (`config :bitblocks, :raw_block_source`)
    * `:auto` (default): the node's REST interface,
      `GET /rest/block/<hash>.bin` (needs `rest=1` in bitcoin.conf; same host
      and port as RPC, no auth). Any non-200 answer, or no REST at all, falls
      back to `getblock(hash, 0)` over RPC.
    * `:rest` or `:rpc`: that source only.
    * `:off`: never; the per-tx path (`TxidSource` + `TxSources`) does it all.

  ## Size cap
  The block is held in memory while it is worked, so only blocks up to
  `:raw_block_max_bytes` (default 32 MB) take this path. SV's
  `getblockheader` reports no size, so the gate is the stored `size` when a
  raw fetch has recorded it, else `num_tx` at most `:raw_block_max_txs`
  (default 20,000); REST also refuses a body over the cap. Larger blocks
  keep the per-tx path. Streaming a GB block through a bounded parser is the
  follow-up.

  ## Checks
  The first 80 bytes must hash to the block's hash. Every txid is derived
  from its own bytes (double SHA-256, reversed), and the ordered txids must
  rebuild the header's merkleroot. So the bodies, the list and the header
  are all checked before anything is stored.
  """

  require Logger

  alias Bitblocks.Chain.{Block, MerkleVerifier}

  @default_max_bytes 32 * 1024 * 1024

  @doc "True when `block` is small enough to fetch whole (see the size cap)."
  @spec eligible?(Block.t()) :: boolean()
  def eligible?(%Block{} = block) do
    source() != :off and
      case block.size do
        size when is_integer(size) and size > 80 ->
          size <= max_bytes()

        _ ->
          is_integer(block.num_tx) and block.num_tx > 0 and
            block.num_tx <= Application.get_env(:bitblocks, :raw_block_max_txs, 20_000)
      end
  end

  @doc """
  Fetches and checks `block`. Returns `{:ok, txs, stats}` where `txs` is the
  ordered list of `{txid, tx_bytes}` and `stats` is
  `%{source: :rest | :rpc | :file, bytes: n, ms: n, raw: block_bytes}`; or
  `{:error, reason}`. `raw` is the block's exact serialized bytes, checked,
  for the tx store's block object (`Bitblocks.TxStore.BlockObject`); the
  txs are sub-binaries of it, so it costs no extra memory.
  """
  @spec fetch(Block.t(), keyword()) ::
          {:ok, [{String.t(), binary()}], map()} | {:error, term()}
  def fetch(%Block{} = block, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    source = if opts[:dir], do: {:dir, opts[:dir]}, else: source()

    with {:ok, bytes, source} <- download(block.hash, source),
         {:ok, txs} <- parse(bytes),
         :ok <- check(block, bytes, txs) do
      {:ok, txs,
       %{
         source: source,
         bytes: byte_size(bytes),
         ms: System.monotonic_time(:millisecond) - started,
         raw: bytes
       }}
    end
  end

  # An exported block file, <height>-<hash>.bin (Chain.BlockImport).
  defp download(hash, {:dir, dir}) do
    case Path.wildcard(Path.join(dir, "*-#{hash}.bin")) do
      [path | _] ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes, :file}
          {:error, reason} -> {:error, {:file, reason}}
        end

      [] ->
        {:error, :no_block_file}
    end
  end

  defp download(hash, :rest), do: rest(hash)
  defp download(hash, :rpc), do: rpc_raw(hash)

  defp download(hash, :auto) do
    case rest(hash) do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} ->
        Logger.info(
          "RawBlock #{hash}: REST unavailable (#{inspect(reason)}); using getblock(hash, 0)"
        )

        rpc_raw(hash)
    end
  end

  defp rest(hash) do
    case rpc().rest_block(hash, max_bytes()) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes, :rest}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp rpc_raw(hash) do
    with hex when is_binary(hex) <- rpc().getblock(hash, 0),
         {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
      {:ok, bytes, :rpc}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_block_hex}
      other -> {:error, {:unexpected, other}}
    end
  end

  # -- Parsing -------------------------------------------------------------------

  @doc """
  Splits a serialized block into `{txid, tx_bytes}` in block order. Each
  `tx_bytes` is a sub-binary of the block: nothing is copied.
  """
  @spec parse(binary()) :: {:ok, [{String.t(), binary()}]} | {:error, :invalid_block}
  def parse(<<_header::binary-80, rest::binary>>) do
    with {:ok, count, body} <- varint(rest),
         {:ok, txs, <<>>} <- split(body, count, []) do
      {:ok, txs}
    else
      _ -> {:error, :invalid_block}
    end
  end

  def parse(_), do: {:error, :invalid_block}

  @doc """
  Where each tx of `parse/1`'s result sits in the block's bytes, in block
  order: `{txid, offset, length}`. The txs are contiguous after the 80-byte
  header and the tx-count varint, so this is arithmetic, with no re-hashing.
  `txs` must be `parse(block_bytes)`'s list.
  """
  @spec locate(binary(), [{String.t(), binary()}]) ::
          {:ok, [{String.t(), non_neg_integer(), non_neg_integer()}]} | {:error, :invalid_block}
  def locate(<<_header::binary-80, rest::binary>> = block_bytes, txs) do
    total = byte_size(block_bytes)

    with {:ok, _count, body} <- varint(rest),
         start = total - byte_size(body),
         # The txs must fill the block exactly, or they aren't its parse.
         {located, ^total} <-
           Enum.map_reduce(txs, start, fn {txid, tx}, offset ->
             {{txid, offset, byte_size(tx)}, offset + byte_size(tx)}
           end) do
      {:ok, located}
    else
      _ -> {:error, :invalid_block}
    end
  end

  def locate(_, _), do: {:error, :invalid_block}

  defp split(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp split(bytes, n, acc) do
    case tx_size(bytes) do
      {:ok, size} ->
        <<tx::binary-size(size), rest::binary>> = bytes
        split(rest, n - 1, [{txid(tx), tx} | acc])

      :error ->
        :error
    end
  end

  @doc "The txid of serialized tx bytes: double SHA-256, byte-reversed, hex."
  @spec txid(binary()) :: String.t()
  def txid(tx_bytes), do: tx_bytes |> sha256d() |> reverse() |> Base.encode16(case: :lower)

  # The byte length of the tx at the start of `bytes`, by walking its
  # structure (the same layout Chain.RawTx decodes).
  defp tx_size(<<_version::binary-4, rest::binary>> = bytes) do
    with {:ok, rest} <- skip_items(rest, &skip_input/1),
         {:ok, <<_lock::binary-4, rest::binary>>} <- skip_items(rest, &skip_output/1) do
      {:ok, byte_size(bytes) - byte_size(rest)}
    else
      _ -> :error
    end
  end

  defp tx_size(_), do: :error

  defp skip_items(bytes, skip_one) do
    with {:ok, count, rest} <- varint(bytes) do
      Enum.reduce_while(1..count//1, {:ok, rest}, fn _, {:ok, rest} ->
        case skip_one.(rest) do
          {:ok, rest} -> {:cont, {:ok, rest}}
          :error -> {:halt, :error}
        end
      end)
    end
  end

  defp skip_input(<<_outpoint::binary-36, rest::binary>>) do
    with {:ok, rest} <- skip_script(rest), <<_seq::binary-4, rest::binary>> <- rest do
      {:ok, rest}
    else
      _ -> :error
    end
  end

  defp skip_input(_), do: :error

  defp skip_output(<<_sats::binary-8, rest::binary>>), do: skip_script(rest)
  defp skip_output(_), do: :error

  defp skip_script(bytes) do
    with {:ok, len, rest} <- varint(bytes), <<_::binary-size(len), rest::binary>> <- rest do
      {:ok, rest}
    else
      _ -> :error
    end
  end

  defp varint(<<0xFD, n::little-16, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFE, n::little-32, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFF, n::little-64, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<n, rest::binary>>), do: {:ok, n, rest}
  defp varint(_), do: :error

  # -- Checks --------------------------------------------------------------------

  defp check(block, <<header::binary-80, _::binary>>, txs) do
    header_hash = header |> sha256d() |> reverse() |> Base.encode16(case: :lower)
    txids = Enum.map(txs, &elem(&1, 0))

    cond do
      header_hash != String.downcase(block.hash) ->
        {:error, :block_hash_mismatch}

      is_integer(block.num_tx) and block.num_tx > 0 and length(txids) != block.num_tx ->
        {:error, {:tx_count_mismatch, length(txids), block.num_tx}}

      is_binary(block.merkleroot) and block.merkleroot != "" ->
        case MerkleVerifier.verify(txids, block.merkleroot) do
          :ok -> :ok
          {:error, reason} -> {:error, {:merkleroot_verification_failed, reason}}
        end

      true ->
        # Header-only test rows carry no merkleroot; the header hash still matched.
        :ok
    end
  end

  # -- getrawtransaction-shaped JSON -----------------------------------------------

  @doc """
  The `getrawtransaction(txid, 1)` map `TxIngest.store/2` expects, built from
  the bytes: `txid`, `hex`, `version`, `locktime`, `vin` (`coinbase` or
  `txid`/`vout`/`scriptSig`) and `vout` (`value`, `n`, `scriptPubKey` with
  `hex`, `type` and, for P2PKH and P2PK, `addresses`). `asm` is left out.
  """
  @spec tx_json(String.t(), binary()) :: map()
  def tx_json(txid, tx_bytes) do
    <<version::little-32, rest::binary>> = tx_bytes
    {inputs, rest} = read_items(rest, &read_input/1)
    {outputs, <<locktime::little-32>>} = read_items(rest, &read_output/1)

    %{
      "txid" => txid,
      "hex" => Base.encode16(tx_bytes, case: :lower),
      "version" => version,
      "locktime" => locktime,
      "size" => byte_size(tx_bytes),
      "vin" => inputs,
      "vout" => outputs |> Enum.with_index() |> Enum.map(fn {out, n} -> Map.put(out, "n", n) end)
    }
  end

  defp read_items(bytes, read_one) do
    {:ok, count, rest} = varint(bytes)

    {items, rest} =
      Enum.reduce(1..count//1, {[], rest}, fn _, {acc, rest} ->
        {item, rest} = read_one.(rest)
        {[item | acc], rest}
      end)

    {Enum.reverse(items), rest}
  end

  defp read_input(<<prev::binary-32, vout::little-32, rest::binary>>) do
    {script, <<sequence::little-32, rest::binary>>} = read_script(rest)
    hex = Base.encode16(script, case: :lower)

    input =
      if prev == <<0::256>> and vout == 0xFFFFFFFF,
        do: %{"coinbase" => hex, "sequence" => sequence},
        else: %{
          "txid" => prev |> reverse() |> Base.encode16(case: :lower),
          "vout" => vout,
          "scriptSig" => %{"hex" => hex},
          "sequence" => sequence
        }

    {input, rest}
  end

  defp read_output(<<satoshis::little-64, rest::binary>>) do
    {script, rest} = read_script(rest)
    {%{"value" => satoshis / 100_000_000, "scriptPubKey" => script_pub_key(script)}, rest}
  end

  defp read_script(bytes) do
    {:ok, len, rest} = varint(bytes)
    <<script::binary-size(len), rest::binary>> = rest
    {script, rest}
  end

  defp script_pub_key(script) do
    base = %{"hex" => Base.encode16(script, case: :lower)}

    case script do
      <<0x76, 0xA9, 0x14, hash::binary-20, 0x88, 0xAC>> ->
        Map.merge(base, %{"type" => "pubkeyhash", "reqSigs" => 1, "addresses" => [address(hash)]})

      <<len, pubkey::binary-size(len), 0xAC>> when len in [33, 65] ->
        Map.merge(base, %{
          "type" => "pubkey",
          "reqSigs" => 1,
          "addresses" => [address(BSV.Hash.sha256_ripemd160(pubkey))]
        })

      <<0x6A, _::binary>> ->
        Map.put(base, "type", "nulldata")

      <<0x00, 0x6A, _::binary>> ->
        Map.put(base, "type", "nulldata")

      _ ->
        Map.put(base, "type", "nonstandard")
    end
  end

  defp address(pubkey_hash), do: BSV.Address.to_string(%BSV.Address{pubkey_hash: pubkey_hash})

  @doc """
  The address a locking script pays, read from its bytes: P2PKH and P2PK,
  the two forms `tx_json/2` gives `addresses`. nil for any other script.
  """
  @spec script_address(binary()) :: String.t() | nil
  def script_address(<<0x76, 0xA9, 0x14, hash::binary-20, 0x88, 0xAC>>), do: address(hash)

  def script_address(<<len, pubkey::binary-size(len), 0xAC>>) when len in [33, 65],
    do: address(BSV.Hash.sha256_ripemd160(pubkey))

  def script_address(_script), do: nil

  # -- Helpers -------------------------------------------------------------------

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp source, do: Application.get_env(:bitblocks, :raw_block_source, :auto)
  defp max_bytes, do: Application.get_env(:bitblocks, :raw_block_max_bytes, @default_max_bytes)

  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
