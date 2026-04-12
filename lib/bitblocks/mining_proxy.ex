defmodule Bitblocks.MiningProxy do
  @moduledoc """
  Lightweight mining proxy — serves block templates and accepts solutions.

  Polls the BSV node for block templates via getblocktemplate RPC,
  builds a coinbase transaction with the configured payout address,
  computes the merkle root, and serves the 80-byte header fields
  to remote hashers via HTTP.

  When a hasher finds a valid nonce, reconstructs the full block
  and submits it to the node.

  ## Configuration

      config :bitblocks, Bitblocks.MiningProxy,
        coinbase_address: "1YourBSVAddressHere",
        coinbase_message: "mined by bitblocks",
        poll_interval_ms: 5_000,
        enabled: true
  """

  use GenServer
  require Logger

  @poll_interval Application.compile_env(:bitblocks, [__MODULE__, :poll_interval_ms], 5_000)

  defmodule Work do
    @moduledoc false
    defstruct [
      :work_id,
      :version,
      :prev_hash,
      :merkle_root,
      :timestamp,
      :bits,
      :target,
      :height,
      :coinbase_hex,
      :tx_hexes,
      :created_at
    ]
  end

  # -- Public API --------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current work unit, or nil if no template is available."
  def get_work do
    GenServer.call(__MODULE__, :get_work)
  end

  @doc "Submit a nonce solution for the current work."
  def submit(work_id, nonce, timestamp) do
    GenServer.call(__MODULE__, {:submit, work_id, nonce, timestamp}, 30_000)
  end

  @doc "Returns status info about the proxy."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      current_work: nil,
      enabled: config(:enabled, false),
      submissions: 0,
      blocks_found: 0,
      last_error: nil
    }

    if state.enabled do
      send(self(), :poll)
      Logger.info("MiningProxy: started, polling every #{@poll_interval}ms")
    else
      Logger.info("MiningProxy: disabled (set config :bitblocks, Bitblocks.MiningProxy, enabled: true)")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_interval)

    case build_work() do
      {:ok, work} ->
        if is_nil(state.current_work) or work.merkle_root != state.current_work.merkle_root do
          Logger.debug("MiningProxy: new work #{work.work_id} height=#{work.height}")
        end

        {:noreply, %{state | current_work: work, last_error: nil}}

      {:error, reason} ->
        Logger.warning("MiningProxy: template error: #{inspect(reason)}")
        {:noreply, %{state | last_error: inspect(reason)}}
    end
  end

  @impl true
  def handle_call(:get_work, _from, state) do
    {:reply, state.current_work, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       has_work: not is_nil(state.current_work),
       height: if(state.current_work, do: state.current_work.height, else: nil),
       work_id: if(state.current_work, do: state.current_work.work_id, else: nil),
       submissions: state.submissions,
       blocks_found: state.blocks_found,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:submit, work_id, nonce, timestamp}, _from, state) do
    state = %{state | submissions: state.submissions + 1}

    case state.current_work do
      nil ->
        {:reply, {:error, :no_work}, state}

      %Work{work_id: ^work_id} = work ->
        case try_submit(work, nonce, timestamp) do
          {:ok, block_hash} ->
            Logger.info("MiningProxy: BLOCK FOUND! hash=#{block_hash} height=#{work.height}")
            state = %{state | blocks_found: state.blocks_found + 1}
            {:reply, {:ok, block_hash}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %Work{} ->
        {:reply, {:error, :stale_work}, state}
    end
  end

  # -- Template building -------------------------------------------------------

  defp build_work do
    case BitcoinsvCli.getblocktemplate() do
      %{"previousblockhash" => prev_hash, "height" => height} = template ->
        coinbase_hex = build_coinbase(template)
        tx_hexes = Enum.map(template["transactions"] || [], & &1["data"])
        all_txids = [txid_from_hex(coinbase_hex) | Enum.map(template["transactions"] || [], & &1["txid"])]
        merkle_root = compute_merkle_root(all_txids)

        work = %Work{
          work_id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          version: template["version"],
          prev_hash: prev_hash,
          merkle_root: merkle_root,
          timestamp: template["curtime"],
          bits: template["bits"],
          target: template["target"],
          height: height,
          coinbase_hex: coinbase_hex,
          tx_hexes: tx_hexes,
          created_at: System.system_time(:second)
        }

        {:ok, work}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  # -- Coinbase transaction ----------------------------------------------------

  defp build_coinbase(template) do
    height = template["height"]
    value = template["coinbasevalue"]
    address = config(:coinbase_address, nil)
    message = config(:coinbase_message, "bitblocks")

    # Height as script number (BIP34)
    height_bytes = encode_script_number(height)
    height_len = byte_size(height_bytes)

    # Message as bytes
    msg_bytes = message
    msg_len = byte_size(msg_bytes)

    # scriptSig: <height_len> <height> <msg_len> <msg>
    script_sig = <<height_len>> <> height_bytes <> <<msg_len>> <> msg_bytes
    script_sig_len = byte_size(script_sig)

    # Output script: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
    script_pubkey =
      if address do
        address_to_p2pkh_script(address)
      else
        # OP_RETURN with message (unspendable — no address configured)
        op_return_script(message)
      end

    script_pubkey_len = byte_size(script_pubkey)

    # Assemble the transaction
    tx =
      # version
      <<1::little-32>> <>
        # input count
        <<1>> <>
        # prev txid (null for coinbase)
        <<0::256>> <>
        # prev vout (0xFFFFFFFF for coinbase)
        <<0xFFFFFFFF::little-32>> <>
        # scriptSig length + scriptSig
        encode_varint(script_sig_len) <>
        script_sig <>
        # sequence
        <<0xFFFFFFFF::little-32>> <>
        # output count
        <<1>> <>
        # value in satoshis
        <<value::little-64>> <>
        # scriptPubKey length + scriptPubKey
        encode_varint(script_pubkey_len) <>
        script_pubkey <>
        # locktime
        <<0::little-32>>

    Base.encode16(tx, case: :lower)
  end

  # -- Block submission --------------------------------------------------------

  defp try_submit(work, nonce, timestamp) do
    # Reconstruct header
    header = serialize_header(work.version, work.prev_hash, work.merkle_root, timestamp, work.bits, nonce)

    # Verify hash meets target
    hash = sha256d(header)
    hash_int = :binary.decode_unsigned(hash, :big)
    {:ok, target_int} = parse_target(work.target)

    if hash_int > target_int do
      {:error, :hash_above_target}
    else
      # Assemble full block: header + tx count + coinbase + all txs
      tx_count = 1 + length(work.tx_hexes)
      tx_count_varint = encode_varint(tx_count) |> Base.encode16(case: :lower)

      block_hex =
        Base.encode16(header, case: :lower) <>
          tx_count_varint <>
          work.coinbase_hex <>
          Enum.join(work.tx_hexes)

      block_hash = hash |> Base.encode16(case: :lower)

      case BitcoinsvCli.submitblock(block_hex) do
        nil ->
          # submitblock returns null on success
          {:ok, block_hash}

        "accepted" ->
          {:ok, block_hash}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  # -- Binary helpers ----------------------------------------------------------

  defp serialize_header(version, prev_hash, merkle_root, timestamp, bits, nonce) do
    {:ok, prev_bytes} = Base.decode16(prev_hash, case: :mixed)
    {:ok, merkle_bytes} = Base.decode16(merkle_root, case: :mixed)
    bits_int = String.to_integer(bits, 16)

    <<version::little-32>> <>
      reverse_bytes(prev_bytes) <>
      reverse_bytes(merkle_bytes) <>
      <<timestamp::little-32>> <>
      <<bits_int::little-32>> <>
      <<nonce::little-32>>
  end

  defp sha256d(data) do
    :crypto.hash(:sha256, :crypto.hash(:sha256, data))
    |> reverse_bytes()
  end

  defp txid_from_hex(hex) do
    {:ok, raw} = Base.decode16(hex, case: :mixed)

    :crypto.hash(:sha256, :crypto.hash(:sha256, raw))
    |> reverse_bytes()
    |> Base.encode16(case: :lower)
  end

  defp compute_merkle_root([single]), do: single

  defp compute_merkle_root(txids) do
    txids
    |> Enum.map(fn txid ->
      {:ok, bytes} = Base.decode16(txid, case: :mixed)
      reverse_bytes(bytes)
    end)
    |> merkle_level()
    |> reverse_bytes()
    |> Base.encode16(case: :lower)
  end

  defp merkle_level([root]), do: root

  defp merkle_level(hashes) do
    # If odd number, duplicate the last
    hashes = if rem(length(hashes), 2) == 1, do: hashes ++ [List.last(hashes)], else: hashes

    hashes
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] ->
      :crypto.hash(:sha256, :crypto.hash(:sha256, a <> b))
    end)
    |> merkle_level()
  end

  defp reverse_bytes(bytes), do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp encode_varint(n) when n < 0xFD, do: <<n>>
  defp encode_varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp encode_varint(n) when n <= 0xFFFFFFFF, do: <<0xFE, n::little-32>>
  defp encode_varint(n), do: <<0xFF, n::little-64>>

  defp encode_script_number(n) when n < 0, do: <<>>

  defp encode_script_number(n) do
    bytes = :binary.encode_unsigned(n, :little)

    # If the high bit is set, append a 0x00 byte
    if :binary.at(bytes, byte_size(bytes) - 1) > 0x7F do
      bytes <> <<0>>
    else
      bytes
    end
  end

  defp address_to_p2pkh_script(address) do
    # Decode base58check address: returns {:ok, <<version, hash::20-bytes>>}
    case B58.version_decode58_check(address) do
      {:ok, <<_version, hash::binary-20>>} ->
        # OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
        <<0x76, 0xA9, 20>> <> hash <> <<0x88, 0xAC>>

      _ ->
        Logger.warning("MiningProxy: invalid coinbase_address #{address}, using OP_RETURN")
        op_return_script("invalid address")
    end
  end

  defp op_return_script(message) do
    msg = message |> String.slice(0, 75)
    <<0x6A, byte_size(msg)>> <> msg
  end

  defp parse_target(hex) when is_binary(hex) do
    {:ok, String.to_integer(hex, 16)}
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
