defmodule Bitblocks.Interop.PaymentAcceptance do
  @moduledoc """
  The payment acceptance record, `interop-kit/payment-acceptance/v0`
  (`docs/INTEROP_KIT.md`): which outputs a receiver took as payment, in its
  own words, signed by its identity key.

  The record is RFC 8785 canonical JSON (`Bitblocks.Interop.Jcs`), signed
  with BRC-77 (`Bitblocks.Interop.Brc77`) by `acceptedBy`, and travels as

      {"body": "<the canonical bytes>", "signature": "<the envelope, base64>"}

  so the exact bytes that were signed are never re-serialized.
  Its hash (`hash/1`, SHA-256 in lowercase hex) is what qart's `receipt_v2`
  names as `acceptanceHash`.

  `parse/1` is strict: every field present and no other, each of its type,
  `outputs` sorted by `txid` then `vout`, and the bytes already canonical.
  """

  alias Bitblocks.Interop.{Brc77, Jcs}

  @version "interop-kit/payment-acceptance/v0"
  @fields ~w(version acceptedBy network outputs termsHash evidenceHash acceptedAt)
  @output_fields ~w(txid vout satoshis)
  @networks ~w(bsv:mainnet bsv:testnet)

  @type output :: %{txid: String.t(), vout: non_neg_integer(), satoshis: non_neg_integer()}
  @type record :: %{optional(String.t()) => term()}

  @doc "The record's version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  A record as a map of its fields, `outputs` sorted.

  Takes `accepted_by` (compressed public key, hex), `network`
  (`"bsv:mainnet"` or `"bsv:testnet"`), `outputs`, `accepted_at` (Unix
  seconds), and optional `terms_hash` and `evidence_hash` (hex or nil).
  """
  @spec build(map()) :: record()
  def build(%{accepted_by: by, network: network, outputs: outputs, accepted_at: at} = attrs) do
    %{
      "version" => @version,
      "acceptedBy" => by,
      "network" => network,
      "outputs" =>
        outputs
        |> Enum.map(&%{"txid" => &1.txid, "vout" => &1.vout, "satoshis" => &1.satoshis})
        |> Enum.sort_by(&{&1["txid"], &1["vout"]}),
      "termsHash" => Map.get(attrs, :terms_hash),
      "evidenceHash" => Map.get(attrs, :evidence_hash),
      "acceptedAt" => at
    }
  end

  @doc "The canonical bytes of a record, refusing one that doesn't parse back."
  @spec encode(record()) :: {:ok, binary()} | {:error, atom()}
  def encode(record) do
    with {:ok, bytes} <- Jcs.encode(record),
         {:ok, _} <- parse(bytes),
         do: {:ok, bytes}
  end

  @doc "SHA-256 of the exact bytes, lowercase hex: a receipt's `acceptanceHash`."
  @spec hash(binary()) :: String.t()
  def hash(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Reads canonical bytes as a v0 record.

  Returns `{:ok, record}` or `{:error, reason}`: any `Jcs.decode/1` reason,
  `{:missing_field, name}`, `{:unknown_field, name}`, `:wrong_version`, or
  `{:invalid, name}` for a field of the wrong shape.
  """
  @spec parse(binary()) :: {:ok, record()} | {:error, term()}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, value} <- Jcs.decode(bytes),
         :ok <- object(value),
         :ok <- exact_fields(value, @fields),
         :ok <- fields(value),
         do: {:ok, value}
  end

  @doc """
  Signs a record's canonical bytes with the identity key `privkey`, which
  must be the record's `acceptedBy`, under the 32-byte `key_id`.

  Returns `{:ok, %{"body" => bytes, "signature" => base64}}`.
  """
  @spec sign(binary(), <<_::256>>, <<_::256>>) :: {:ok, map()} | {:error, term()}
  def sign(bytes, privkey, key_id) do
    with {:ok, record} <- parse(bytes),
         true <-
           record["acceptedBy"] == Base.encode16(Brc77.public_key(privkey), case: :lower) ||
             {:error, :signer_mismatch} do
      envelope = Brc77.sign(bytes, privkey, key_id)
      {:ok, %{"body" => bytes, "signature" => Base.encode64(envelope)}}
    end
  end

  @doc """
  Checks a signed record: `{"body", "signature"}`, as a map or as JSON text.

  The body must parse as a v0 record, the signature must be a BRC-77
  anyone envelope over its exact bytes, and the envelope's signer must be
  `acceptedBy`. Returns `{:ok, record}` or `{:error, reason}`, where reason
  is any `parse/1` reason, `:malformed`, `:malformed_envelope`,
  `:not_anyone`, `:signature_fails`, or `{:signer_mismatch, signer_hex}`.
  """
  @spec verify(map() | binary()) :: {:ok, record()} | {:error, term()}
  def verify(signed) when is_binary(signed) do
    case Jason.decode(signed) do
      {:ok, map} when is_map(map) -> verify(map)
      _ -> {:error, :malformed}
    end
  end

  def verify(%{"body" => body, "signature" => signature} = signed)
      when is_binary(body) and is_binary(signature) and map_size(signed) == 2 do
    with {:ok, record} <- parse(body),
         {:ok, envelope} <- base64(signature),
         {:ok, signer} <- Brc77.verify(body, envelope),
         signer = Base.encode16(signer, case: :lower),
         true <- signer == record["acceptedBy"] || {:error, {:signer_mismatch, signer}} do
      {:ok, record}
    end
  end

  def verify(_signed), do: {:error, :malformed}

  defp base64(text) do
    case Base.decode64(text) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed_envelope}
    end
  end

  defp object(value) when is_map(value), do: :ok
  defp object(_value), do: {:error, :not_an_object}

  defp exact_fields(map, fields) do
    keys = Map.keys(map)

    case {fields -- keys, Enum.sort(keys -- fields)} do
      {[], []} -> :ok
      {[missing | _], _} -> {:error, {:missing_field, missing}}
      {[], [extra | _]} -> {:error, {:unknown_field, extra}}
    end
  end

  defp fields(%{"version" => version}) when version != @version, do: {:error, :wrong_version}

  defp fields(record) do
    cond do
      not pubkey?(record["acceptedBy"]) ->
        {:error, {:invalid, "acceptedBy"}}

      record["network"] not in @networks ->
        {:error, {:invalid, "network"}}

      not outputs?(record["outputs"]) ->
        {:error, {:invalid, "outputs"}}

      not hash_or_nil?(record["termsHash"]) ->
        {:error, {:invalid, "termsHash"}}

      not hash_or_nil?(record["evidenceHash"]) ->
        {:error, {:invalid, "evidenceHash"}}

      not (is_integer(record["acceptedAt"]) and record["acceptedAt"] >= 0) ->
        {:error, {:invalid, "acceptedAt"}}

      true ->
        :ok
    end
  end

  defp pubkey?(<<prefix::binary-2, rest::binary-64>>) when prefix in ["02", "03"],
    do: lower_hex?(rest)

  defp pubkey?(_), do: false

  defp hash_or_nil?(nil), do: true
  defp hash_or_nil?(<<_::binary-64>> = hex), do: lower_hex?(hex)
  defp hash_or_nil?(_), do: false

  defp lower_hex?(s), do: s =~ ~r/\A[0-9a-f]*\z/

  defp outputs?(outputs) when is_list(outputs) do
    Enum.all?(outputs, &output?/1) and
      outputs == Enum.sort_by(outputs, &{&1["txid"], &1["vout"]}) and
      outputs == Enum.uniq_by(outputs, &{&1["txid"], &1["vout"]})
  end

  defp outputs?(_), do: false

  defp output?(%{"txid" => txid, "vout" => vout, "satoshis" => sats} = output) do
    exact_fields(output, @output_fields) == :ok and hash_or_nil?(txid) and is_binary(txid) and
      is_integer(vout) and vout >= 0 and is_integer(sats) and sats >= 0
  end

  defp output?(_), do: false
end
