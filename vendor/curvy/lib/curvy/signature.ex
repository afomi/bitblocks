defmodule Curvy.Signature do
  @moduledoc """
  Module for converting signature R and S values to DER encoded or compact
  binaries.
  """
  import Bitwise
  alias Curvy.Curve

  defstruct crv: :secp256k1,
            r: nil,
            s: nil,
            recid: nil

  @typedoc "ECDSA Signature"
  @type t :: %__MODULE__{
    crv: atom,
    r: integer,
    s: integer,
    recid: recovery_id | nil
  }

  @typedoc "Recovery ID"
  @type recovery_id :: 0 | 1 | 2 | 3

  @crv Curve.secp256k1


  @doc """
  Parsed the given binary signature in a [`Signature`](`t:t`) struct.

  Parsed DER encoded and compact signatures. Returns `:error` if unable to parse.

  DER signatures must be strictly encoded (as BIP 66 requires): the sequence
  length matches the content, and each integer is 1 to 33 bytes, positive and
  minimally encoded. Anything else is `:error`, so one signature has only one
  accepted encoding.
  """
  @spec parse(binary) :: t | :error
  def parse(<<0x30, len, 0x02, rlen, rbin::bytes-size(rlen), 0x02, slen, sbin::bytes-size(slen)>>)
    when len == 4 + rlen + slen
  do
    if strict_der_int?(rbin) and strict_der_int?(sbin) do
      %__MODULE__{
        r: :binary.decode_unsigned(rbin),
        s: :binary.decode_unsigned(sbin)
      }
    else
      :error
    end
  end

  # 0x30 is never a compact prefix (27..34), so a failed DER parse is an error.
  def parse(<<0x30, _rest::binary>>), do: :error

  def parse(<<prefix::integer, r::big-size(256), s::big-size(256)>>) when prefix in 27..34 do
    recid = case prefix - 27 - 4 do
      recid when recid < 0 ->
        recid + 4
      recid ->
        recid
    end
    %__MODULE__{r: r, s: s, recid: recid}
  end

  def parse(_sig), do: :error


  @doc """
  Normalizes the signature by enforcing Low-S values.

  Returns a [`Signature`](`t:t`).

  See [BIP 62](https://github.com/bitcoin/bips/blob/master/bip-0062.mediawiki)
  for more info.
  """
  @spec normalize(t) :: t
  def normalize(%__MODULE__{s: s} = sig) when s > bsr(@crv.n, 1) do
    sig
    |> Map.put(:s, @crv.n - s)
    |> case do
      %__MODULE__{recid: recid} = sig when recid in 0..3 ->
        Map.put(sig, :recid, Bitwise.bxor(recid, 1))
      sig ->
        sig
    end
  end

  def normalize(%__MODULE__{} = sig), do: sig


  @doc """
  Returns the signature as a DER-encoded binary.
  """
  @spec to_der(t) :: binary
  def to_der(%__MODULE__{r: r, s: s}, _opts \\ []) do
    rbin = der_encode_int(r)
    sbin = der_encode_int(s)
    rlen = byte_size(rbin)
    slen = byte_size(sbin)

    <<
      0x30,                 # header
      2 + rlen + 2 + slen,  # length
      0x02,                 # r header
      rlen,                 # r length
      rbin::binary,         # r
      0x02,                 # s header
      slen,                 # s length
      sbin::binary          # s
    >>
  end


  @doc """
  Returns the signature as a 65 byte compact binary.
  """
  @spec to_compact(t, keyword) :: binary
  def to_compact(%__MODULE__{r: r, s: s, recid: recid}, opts \\ []) do
    with recid when recid in 0..3 <- Keyword.get(opts, :recovery_id, recid) do
      prefix = case Keyword.get(opts, :compressed, true) do
        true -> recid + 27 + 4
        false -> recid + 27
      end

      <<
        prefix,             # recovery
        r::big-size(256),   # r
        s::big-size(256)    # s
      >>
    else
      _ ->
        raise "Recovery ID not in range 0..3"
    end
  end


  # A strict DER integer: 1..33 bytes, not negative, no unneeded leading zero.
  defp strict_der_int?(<<>>), do: false
  defp strict_der_int?(bin) when byte_size(bin) > 33, do: false
  defp strict_der_int?(<<n, _::binary>>) when band(n, 0x80) != 0, do: false
  defp strict_der_int?(<<0, n, _::binary>>) when band(n, 0x80) == 0, do: false
  defp strict_der_int?(_bin), do: true


  # DER encodes the given integer
  defp der_encode_int(int) when is_integer(int) do
    <<n::integer, _::binary>> = bin = :binary.encode_unsigned(int)
    case band(n, 0x80) do
      0 -> bin
      _ -> <<0, bin::binary>>
    end
  end

end
