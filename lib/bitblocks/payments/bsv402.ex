defmodule Bitblocks.Payments.Bsv402 do
  @moduledoc """
  Paying for one request in BSV, as BRC-121 (Simple 402 Payments) describes,
  checked against our own headers and our own node (docs/BSV_402.md).

  The 402 that `BitblocksWeb.Plugs.RateLimiter` sends past a shared budget
  carries our terms, `x-bsv-sats` and `x-bsv-server` (`terms/0`). The client's
  wallet pays one P2PKH output of that many satoshis to a key derived by
  BRC-29 from our identity key, and the client sends the same request again
  with `x-bsv-beef` (Atomic BEEF, base64), `x-bsv-sender`, `x-bsv-nonce`,
  `x-bsv-time` and `x-bsv-vout`. `verify/3` checks it, cheapest first:

    1. all five present and well formed (`incomplete`, `malformed`), the BEEF
       under `max_beef_bytes/0` (`too_large`);
    2. `x-bsv-time` within 30 seconds of our clock (`stale`);
    3. the BEEF reads as Atomic BEEF (`malformed`);
    4. its txid isn't already claimed (`replayed`), unless the claim is for
       this same request, which is served again (`reserved`) so a client whose
       response was lost doesn't pay twice;
    4a. its sender isn't on the deny list, a payment of theirs dropped or
       conflicted lately (`denied`, `Bsv402.Confirmation`);
    5. the output at `x-bsv-vout` is P2PKH to the key we derive with our
       private key, the sender's key and the key ID
       `<nonce> <base64(time)>` under protocol `[2, "3241645161d8"]`
       (`not_our_output`), holding at least the price (`underpaid`);
    6. its ancestry proves against our headers (`Chain.BeefVerifier`): the
       payment `proven` or `anchored` (`unproven`, or `unknown_block` when a
       BUMP names a height we hold no header we'd rely on for);
    7. the txid is claimed in `bsv_payments` (unique, so a concurrent second
       request loses: `replayed`);
    8. the raw transaction goes to our node, which runs the scripts and
       refuses a double spend of its mempool; "already known" counts as
       taken. A refusal (`broadcast_rejected`) or an unreachable node
       (`broadcast_unavailable`, a 503) deletes the claim, so the same BEEF
       can be sent again.

  No script is run here, and no third party decides.

  ## Configuration

  Off unless set (`config/runtime.exs`), and then only with a key and a price:

      config :bitblocks, Bitblocks.Payments.Bsv402,
        enabled: true,                  # BSV402_ENABLED
        price_sats: "…",                # BSV402_PRICE_SATS, set by Ryan
        identity_key_env: "BSV402_IDENTITY_KEY",
        max_beef_bytes: 12_000

  The identity key is read from the environment variable named by
  `identity_key_env` each time it is needed, so it never sits in the app's
  config, and it is held in an `IdentityKey` whose inspect shows only the
  public half. It is never logged. `status/0` and `missing/0` name what is
  missing, never a value.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{BeefVerifier, Headers, RawTx}
  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.Interop.Brc42
  alias Bitblocks.Payments.Bsv402.Confirmation
  alias Bitblocks.Payments.BsvPayment
  alias Bitblocks.Repo

  defmodule IdentityKey do
    @moduledoc """
    Our BRC-121 identity key: the private half, which derives (and could
    spend) each payment's key, and the public half we publish. Inspect shows
    only the public half.
    """
    @enforce_keys [:private, :public]
    defstruct [:private, :public]

    @type t :: %__MODULE__{private: <<_::256>>, public: <<_::264>>}

    defimpl Inspect do
      def inspect(%{public: public}, _opts),
        do:
          "#Bitblocks.Payments.Bsv402.IdentityKey<public: #{Base.encode16(public, case: :lower)}>"
    end
  end

  # BRC-29's protocol, as BRC-121 and @bsv/402-pay use it.
  @protocol "2-3241645161d8"
  @window_ms 30_000
  # Below Bandit's per-header limit (config/runtime.exs) and the load
  # balancer's 16 KB, once base64 has made it 4/3 as long.
  @default_max_beef_bytes 12_000
  # A few dozen ancestors at most: each one costs a climb.
  @max_transactions 64
  @max_bumps 64

  @payment_headers ~w(x-bsv-beef x-bsv-sender x-bsv-nonce x-bsv-time x-bsv-vout)

  @reasons %{
    incomplete:
      "A paid request carries all five of x-bsv-beef, x-bsv-sender, x-bsv-nonce, x-bsv-time and x-bsv-vout.",
    malformed:
      "The payment headers don't read: x-bsv-beef must be Atomic BEEF (BRC-95) in base64, x-bsv-sender a compressed public key, x-bsv-nonce base64, x-bsv-time and x-bsv-vout decimal.",
    too_large: "x-bsv-beef is larger than we take in a header.",
    stale: "x-bsv-time is more than 30 seconds from our clock.",
    replayed: "This payment has already bought a request.",
    not_our_output:
      "The output at x-bsv-vout isn't P2PKH to the key BRC-29 derives for us from x-bsv-sender, x-bsv-nonce and x-bsv-time.",
    underpaid: "The output at x-bsv-vout holds less than x-bsv-sats.",
    unproven: "The payment's ancestry doesn't prove against the headers we hold.",
    unknown_block:
      "The payment's ancestry names a block we hold no header we rely on for, so it can't be checked yet.",
    broadcast_rejected: "Our node refused the payment transaction.",
    broadcast_unavailable:
      "Our node couldn't be reached, so the payment wasn't taken; the same payment can be sent again.",
    denied:
      "Payments from this x-bsv-sender are refused for now: an earlier one was dropped or conflicted.",
    unavailable: "We couldn't record the payment, so it wasn't taken; try again shortly."
  }

  @type reason ::
          :incomplete
          | :malformed
          | :too_large
          | :stale
          | :replayed
          | :not_our_output
          | :underpaid
          | :unproven
          | :unknown_block
          | :broadcast_rejected
          | :broadcast_unavailable
          | :denied
          | :unavailable

  @type accepted :: %{
          outcome: :accepted | :reserved,
          txid: String.t(),
          vout: non_neg_integer(),
          satoshis: non_neg_integer(),
          sender_key: String.t()
        }

  @type refused :: %{reason: reason(), status: 402 | 413 | 503, detail: String.t()}

  @type node_answer :: :accepted | :already_known | {:rejected, String.t()} | :unavailable

  # --- configuration ------------------------------------------------------------

  @doc "The five request headers a paid retry carries, in BRC-121's order."
  @spec payment_headers() :: [String.t()]
  def payment_headers, do: @payment_headers

  @doc "The freshness window on `x-bsv-time`, in milliseconds (BRC-121: 30 seconds)."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "The largest Atomic BEEF we take in `x-bsv-beef`, in bytes once decoded."
  @spec max_beef_bytes() :: pos_integer()
  def max_beef_bytes, do: config(:max_beef_bytes, @default_max_beef_bytes)

  @doc "True when payments can be taken: enabled, with a valid identity key and a price."
  @spec enabled?() :: boolean()
  def enabled?, do: status() == :ok

  @doc """
  Why BSV payments are off, or `:ok`. For the boot log, `Release.status/1`
  and `Release.bsv402_status/0`.
  """
  @spec status() :: :ok | :disabled | :no_identity_key | :invalid_identity_key | :no_price
  def status do
    if config(:enabled, false) != true do
      :disabled
    else
      case identity() do
        :none -> :no_identity_key
        :invalid -> :invalid_identity_key
        {:ok, _} -> if price_sats() == nil, do: :no_price, else: :ok
      end
    end
  end

  @doc """
  What stands between this config and taking a payment, each in plain words
  naming the variable to set; empty when nothing does. Names variables,
  never values.
  """
  @spec missing() :: [String.t()]
  def missing do
    env = identity_key_env()

    [
      config(:enabled, false) != true &&
        "BSV402_ENABLED is not true (set it to true to offer BSV payment on the 402)",
      identity() == :none &&
        "#{env} is not set (a dedicated private key, 64 hex digits or WIF)",
      identity() == :invalid &&
        "#{env} is set but isn't a private key (64 hex digits or WIF)",
      price_sats() == nil &&
        "BSV402_PRICE_SATS is not set to a whole number of satoshis above 0"
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc "The environment variable the identity key is read from."
  @spec identity_key_env() :: String.t()
  def identity_key_env, do: config(:identity_key_env, "BSV402_IDENTITY_KEY")

  @doc """
  Our identity key, read from the environment now: `{:ok, key}`, `:none`
  when unset, or `:invalid`. The value never leaves this module but inside
  an `IdentityKey`.
  """
  @spec identity() :: {:ok, IdentityKey.t()} | :none | :invalid
  def identity do
    case System.get_env(identity_key_env()) do
      value when value in [nil, ""] ->
        :none

      value ->
        case Brc42.decode_private(value) do
          {:ok, private} -> {:ok, identity_from(private)}
          :invalid -> :invalid
        end
    end
  end

  @doc "An `IdentityKey` for a 32-byte private key (the vectors' test key, say)."
  @spec identity_from(<<_::256>>) :: IdentityKey.t()
  def identity_from(<<_::256>> = private) do
    # The public half is a curve multiplication; every 402 names it, so it is
    # worked out once per key and kept by the key's hash, never the key.
    cache = {__MODULE__, :public, :crypto.hash(:sha256, private)}

    public =
      case :persistent_term.get(cache, nil) do
        nil ->
          public = Brc42.public_key(private)
          :persistent_term.put(cache, public)
          public

        public ->
          public
      end

    %IdentityKey{private: private, public: public}
  end

  @doc "Our identity key's public half, compressed hex, or nil while there is none."
  @spec identity_public() :: String.t() | nil
  def identity_public do
    case identity() do
      {:ok, %{public: public}} -> hex(public)
      _ -> nil
    end
  end

  @doc "The price of one request, in satoshis (`BSV402_PRICE_SATS`), or nil while unset."
  @spec price_sats() :: pos_integer() | nil
  def price_sats do
    case config(:price_sats, nil) do
      n when is_integer(n) and n > 0 ->
        n

      text when is_binary(text) ->
        case Integer.parse(String.trim(text)) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The terms a 402 carries, as response headers: `x-bsv-sats` and
  `x-bsv-server`. Empty while payments are off, so no price shows that
  can't be paid.
  """
  @spec terms() :: [{String.t(), String.t()}]
  def terms do
    with true <- config(:enabled, false) == true,
         price when is_integer(price) <- price_sats(),
         {:ok, %{public: public}} <- identity() do
      [{"x-bsv-sats", Integer.to_string(price)}, {"x-bsv-server", hex(public)}]
    else
      _ -> []
    end
  end

  @doc "The plain-words meaning of a refusal reason."
  @spec detail(reason()) :: String.t()
  def detail(reason), do: Map.fetch!(@reasons, reason)

  @doc "SHA-256 of method, path and query, hex: what a payment bought."
  @spec request_hash(String.t(), String.t(), String.t() | nil) :: String.t()
  def request_hash(method, path, query) do
    :crypto.hash(:sha256, [method, " ", path, "?", query || ""]) |> hex()
  end

  @doc "The BRC-43 invoice number BRC-29 derives a payment's key under."
  @spec invoice(String.t(), String.t()) :: String.t()
  def invoice(prefix, time), do: "#{@protocol}-#{prefix} #{suffix(time)}"

  @doc "BRC-121's derivation suffix: the base64 of the `x-bsv-time` text."
  @spec suffix(String.t()) :: String.t()
  def suffix(time), do: Base.encode64(time)

  # --- the check ------------------------------------------------------------------

  @doc """
  Checks, claims and broadcasts the payment on this request (`verify/3`, with
  our key, price, headers and node).
  """
  @spec handle(Plug.Conn.t(), keyword()) :: {:ok, accepted()} | {:error, refused()}
  def handle(%Plug.Conn{} = conn, opts \\ []) do
    payment =
      Map.new(@payment_headers, fn name ->
        {name, conn |> Plug.Conn.get_req_header(name) |> List.first()}
      end)

    request = %{method: conn.method, path: conn.request_path, query: conn.query_string}

    verify(payment, request, opts)
  end

  @doc """
  Checks one payment for one request, claims it and has our node take it.

  `payment` maps the five header names to their values (nil when absent).
  `request` is `%{method:, path:, query:}`. Options, each defaulting to ours:

    * `:identity`: an `IdentityKey`;
    * `:price`: satoshis;
    * `:now_ms`: our clock;
    * `:headers`: `fn heights -> %{height => header} end`, as `Chain.Headers.heights/1`;
    * `:tip`: our tip height;
    * `:broadcast`: `fn raw_tx -> node_answer end`, our node by default (`broadcast/1`);
    * `:denied?`: `fn sender_key_hex -> boolean end`, the deny list by default;
    * `:caller`: who the claimed row names, the payer's identity key by
      default (`"key:<id>"` for a keyed caller, `RateLimiter`);
    * `:max_beef_bytes`.

  `{:ok, accepted}` to serve the request, or `{:error, refused}` with the
  status to answer.
  """
  @spec verify(map(), map(), keyword()) :: {:ok, accepted()} | {:error, refused()}
  def verify(payment, request, opts \\ []) when is_map(payment) and is_map(request) do
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    request_hash = request_hash(request.method, request.path, request[:query])

    with {:ok, fields} <- fields(payment, Keyword.get(opts, :max_beef_bytes, max_beef_bytes())),
         :ok <- fresh(fields.time_ms, now),
         {:ok, beef, raw} <- read(fields.beef),
         :new <- prior(beef.subject, request_hash, fields),
         :ok <- not_denied(fields.sender, opts),
         {:ok, identity} <- identity_opt(opts),
         {:ok, satoshis} <- output(raw, fields, identity, price_opt(opts)),
         :ok <- proven(beef, opts),
         :ok <- claim(beef.subject, raw, satoshis, fields, request_hash, opts),
         :ok <- send_to_node(beef.subject, raw, opts) do
      {:ok, accepted(:accepted, beef.subject, fields, satoshis)}
    else
      {:reserved, accepted} -> {:ok, accepted}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp identity_opt(opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, %IdentityKey{} = key} ->
        {:ok, key}

      :error ->
        case identity() do
          {:ok, key} -> {:ok, key}
          _ -> {:error, :unavailable}
        end
    end
  end

  defp price_opt(opts), do: Keyword.get_lazy(opts, :price, &price_sats/0)

  defp accepted(outcome, txid, fields, satoshis) do
    %{
      outcome: outcome,
      txid: txid,
      vout: fields.vout,
      satoshis: satoshis,
      sender_key: hex(fields.sender)
    }
  end

  defp refusal(reason) do
    status =
      case reason do
        :too_large -> 413
        :broadcast_unavailable -> 503
        :unavailable -> 503
        _ -> 402
      end

    %{reason: reason, status: status, detail: detail(reason)}
  end

  # 1. Present and well formed. The BEEF's size is checked before decoding.
  defp fields(payment, max_beef_bytes) do
    values = Enum.map(@payment_headers, &Map.get(payment, &1))

    if Enum.any?(values, &(&1 in [nil, ""])) do
      {:error, :incomplete}
    else
      [beef, sender, nonce, time, vout] = Enum.map(values, &String.trim/1)

      with :ok <- beef_size(beef, max_beef_bytes),
           {:ok, beef} <- canonical_base64(beef),
           :ok <- if(byte_size(beef) <= max_beef_bytes, do: :ok, else: {:error, :too_large}),
           {:ok, sender} <- public_key(sender),
           true <- byte_size(nonce) <= 512 or {:error, :malformed},
           {:ok, _} <- canonical_base64(nonce),
           {:ok, time_ms} <- decimal(time, 16),
           {:ok, vout} <- decimal(vout, 10) do
        {:ok,
         %{beef: beef, sender: sender, nonce: nonce, time: time, time_ms: time_ms, vout: vout}}
      end
    end
  end

  defp beef_size(beef, max_beef_bytes) do
    if byte_size(beef) <= div(max_beef_bytes + 2, 3) * 4, do: :ok, else: {:error, :too_large}
  end

  defp canonical_base64(text) do
    case Base.decode64(text) do
      {:ok, bytes} when bytes != "" ->
        if Base.encode64(bytes) == text, do: {:ok, bytes}, else: {:error, :malformed}

      _ ->
        {:error, :malformed}
    end
  end

  defp public_key(text) do
    with <<_::binary-66>> <- text,
         {:ok, key} <- Base.decode16(text, case: :mixed),
         true <- Brc42.valid_public?(key) do
      {:ok, key}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decimal(text, max_digits) do
    if byte_size(text) <= max_digits and Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, text),
      do: {:ok, String.to_integer(text)},
      else: {:error, :malformed}
  end

  # 2. BRC-121's 30 seconds, either way.
  defp fresh(time_ms, now) do
    if abs(now - time_ms) <= @window_ms, do: :ok, else: {:error, :stale}
  end

  # 3. Atomic BEEF only: it names the payment.
  defp read(bytes) do
    case Reader.parse(bytes,
           max_bytes: byte_size(bytes),
           max_transactions: @max_transactions,
           max_bumps: @max_bumps
         ) do
      {:ok, %{atomic: true, subject: subject, transactions: txs} = beef} ->
        case Enum.find(txs, &(&1.txid == subject)) do
          %{raw: raw} when is_binary(raw) -> {:ok, beef, raw}
          _ -> {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  # 4. Claimed already? The same request is served again; any other is a replay.
  defp prior(txid, request_hash, fields) do
    case Repo.one(
           from p in BsvPayment,
             where: p.txid == ^txid,
             select: %{request_hash: p.request_hash, vout: p.vout, satoshis: p.satoshis}
         ) do
      nil ->
        :new

      %{request_hash: ^request_hash, satoshis: satoshis} ->
        {:reserved, accepted(:reserved, txid, fields, satoshis)}

      _ ->
        {:error, :replayed}
    end
  rescue
    e ->
      Logger.error("BSV 402 claim lookup failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  # 4a. The deny list: a sender whose payment was dropped or conflicted lately
  # (Bsv402.Confirmation). After the claimed check, so a lost response for a
  # payment already taken is still served again.
  defp not_denied(sender, opts) do
    denied? = Keyword.get(opts, :denied?, &Confirmation.denied?/1)

    if denied?.(hex(sender)), do: {:error, :denied}, else: :ok
  rescue
    e ->
      Logger.error("BSV 402 deny-list check failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  # 5. The named output pays the key we derive, at least the price.
  defp output(raw, fields, identity, price) do
    with {:ok, %{outputs: outputs}} <- RawTx.flows(hex(raw)),
         {:ok, {satoshis, script}} <- Enum.fetch(outputs, fields.vout),
         {:ok, child} <-
           Brc42.private_child(
             identity.private,
             fields.sender,
             invoice(fields.nonce, fields.time)
           ),
         true <- script == p2pkh(Brc42.public_key(child)) || {:error, :not_our_output},
         true <- (is_integer(price) and satoshis >= price) || {:error, :underpaid} do
      {:ok, satoshis}
    else
      {:error, :underpaid} -> {:error, :underpaid}
      _ -> {:error, :not_our_output}
    end
  end

  defp p2pkh(public_key) do
    hash = :crypto.hash(:ripemd160, :crypto.hash(:sha256, public_key))
    <<0x76, 0xA9, 0x14, hash::binary, 0x88, 0xAC>>
  end

  # 6. Against our headers: proven, or anchored in proven parents.
  defp proven(beef, opts) do
    heights = beef.bumps |> Enum.map(& &1.height) |> Enum.uniq()
    tip = Keyword.get_lazy(opts, :tip, &Bitblocks.Sync.tip/0)
    headers = Keyword.get(opts, :headers, &Headers.heights/1).(heights ++ List.wrap(tip))
    answer = BeefVerifier.evaluate(beef, headers, tip)

    cond do
      answer.status in [:proven, :anchored] ->
        :ok

      answer.status == :unknown and
          Enum.any?(
            answer.transactions,
            &(&1.reason in [:height_unknown, :header_unverified, :not_canonical])
          ) ->
        {:error, :unknown_block}

      true ->
        {:error, :unproven}
    end
  rescue
    e ->
      Logger.error("BSV 402 header check failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  # 7. One insert behind the unique txid: of two requests, one wins.
  defp claim(txid, raw, satoshis, fields, request_hash, opts) do
    stamp = DateTime.utc_now()
    price = price_opt(opts)

    row = %{
      txid: txid,
      vout: fields.vout,
      satoshis: satoshis,
      sender_key: hex(fields.sender),
      derivation_prefix: fields.nonce,
      derivation_suffix: suffix(fields.time),
      raw_tx: raw,
      request_hash: request_hash,
      envelope: "brc121",
      price_sats: price,
      status: "accepted",
      caller: Keyword.get_lazy(opts, :caller, fn -> hex(fields.sender) end),
      accepted_at: stamp,
      inserted_at: stamp,
      updated_at: stamp
    }

    case Repo.insert_all(BsvPayment, [row], on_conflict: :nothing, conflict_target: [:txid]) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  rescue
    e ->
      Logger.error("BSV 402 claim failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  # 8. Our node decides; a refusal or no answer takes the claim back.
  defp send_to_node(txid, raw, opts) do
    case Keyword.get(opts, :broadcast, &broadcast/1).(raw) do
      answer when answer in [:accepted, :already_known] ->
        :ok

      {:rejected, message} ->
        Logger.info("BSV 402 payment #{txid} refused by our node: #{message}")
        unclaim(txid)
        {:error, :broadcast_rejected}

      _unavailable ->
        Logger.warning("BSV 402 payment #{txid} not taken: our node didn't answer")
        unclaim(txid)
        {:error, :broadcast_unavailable}
    end
  end

  defp unclaim(txid) do
    Repo.delete_all(from p in BsvPayment, where: p.txid == ^txid)
    :ok
  rescue
    e ->
      Logger.error("BSV 402 unclaim of #{txid} failed: #{inspect(e.__struct__)}")
      :ok
  end

  @doc """
  Sends a raw transaction to our node (`sendrawtransaction`): `:accepted`,
  `:already_known` (in its mempool or a block), `{:rejected, reason}`, or
  `:unavailable` when the node doesn't answer.
  """
  @spec broadcast(binary()) :: node_answer()
  def broadcast(raw) when is_binary(raw) do
    case rpc().sendrawtransaction(hex(raw)) do
      txid when is_binary(txid) -> :accepted
      {:error, %{"message" => message} = error} -> node_error(error["code"], message)
      _ -> :unavailable
    end
  end

  # -28 warming up, -32005 rate limited: the node didn't decide.
  defp node_error(code, _message) when code in [-28, -32005], do: :unavailable
  # RPC_VERIFY_ALREADY_IN_CHAIN.
  defp node_error(-27, _message), do: :already_known

  defp node_error(_code, message) when is_binary(message) do
    if Regex.match?(~r/already[- _](known|in[- _]mempool|in[- _]block)/i, message),
      do: :already_known,
      else: {:rejected, message |> String.replace(~r/[^\x20-\x7e]/, "") |> String.slice(0, 200)}
  end

  defp node_error(_code, _message), do: {:rejected, "refused"}

  # --- counts ----------------------------------------------------------------------

  @doc """
  Payments taken so far, by status, as `%{"accepted" => n}`; nil while the
  database can't say. For `Release.bsv402_status/0`.
  """
  @spec counts() :: %{String.t() => non_neg_integer()} | nil
  def counts do
    from(p in BsvPayment, group_by: p.status, select: {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  rescue
    e ->
      Logger.error("BSV 402 counts failed: #{inspect(e.__struct__)}")
      nil
  end

  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
