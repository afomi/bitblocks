defmodule Curvy.Key do
  @moduledoc """
  Module used to create ECDSA keypairs and convert to private and public key
  binaries.
  """
  alias Curvy.{Curve, Point}

  defstruct crv: :secp256k1,
            point: %Point{},
            privkey: nil,
            compressed: true


  @typedoc """
  ECDSA Keypair.

  Always contains the `t:Point.t` coordinates and optionally a private key binary.
  """
  @type t :: %__MODULE__{
    crv: atom,
    point: Point.t,
    privkey: binary | nil,
    compressed: boolean
  }

  @crv Curve.secp256k1


  @doc """
  Creates a new random ESCDA keypair.
  """
  @spec generate(keyword) :: t
  def generate(opts \\ []) do
    compressed = Keyword.get(opts, :compressed, true)
    {pubkey, privkey} = :crypto.generate_key(:ecdh, :secp256k1)
    <<_::integer, x::big-size(256), y::big-size(256)>> = pubkey

    %__MODULE__{
      point: %Point{x: x, y: y},
      privkey: privkey,
      compressed: compressed
    }
  end


  @doc """
  Converts the given private key binary to a [`ECDSA Keypair`](`t:t`).
  """
  @spec from_privkey(binary, keyword) :: t
  def from_privkey(<<privkey::binary-size(32)>>, opts \\ []) do
    compressed = Keyword.get(opts, :compressed, true)
    {pubkey, _privkey} = :crypto.generate_key(:ecdh, :secp256k1, privkey)
    <<_::integer, x::big-size(256), y::big-size(256)>> = pubkey

    %__MODULE__{
      point: %Point{x: x, y: y},
      privkey: privkey,
      compressed: compressed
    }
  end


  @doc """
  Converts the given public key binary to a [`ECDSA Keypair`](`t:t`) struct
  without a private key.
  """
  @spec from_pubkey(binary) :: t
  def from_pubkey(pubkey)

  def from_pubkey(<<_::integer, x::big-size(256), y::big-size(256)>>),
    do: %__MODULE__{point: %Point{x: x, y: y}, compressed: false}

  def from_pubkey(<<prefix::integer, x::big-size(256)>>) do
    y = x
    |> :crypto.mod_pow(3, @crv.p)
    |> :binary.decode_unsigned()
    |> Kernel.+(7)
    |> rem(@crv.p)
    |> :crypto.mod_pow(Integer.floor_div(@crv.p + 1, 4), @crv.p)
    |> :binary.decode_unsigned()

    y = if rem(y, 2) != rem(prefix, 2), do: @crv.p - y, else: y

    %__MODULE__{point: %Point{x: x, y: y}, compressed: true}
  end


  @doc """
  Parses and validates the given public key binary.

  Unlike `from_pubkey/1`, which trusts its input, this returns `:error` unless
  the binary is a 33-byte compressed key (prefix `0x02` or `0x03`) or a 65-byte
  uncompressed key (prefix `0x04`) whose point is on secp256k1.
  Use it for public keys from untrusted input.
  """
  @spec parse_pubkey(binary) :: {:ok, t} | :error
  def parse_pubkey(<<4, _::big-size(256), _::big-size(256)>> = pubkey),
    do: pubkey |> from_pubkey() |> validate()

  def parse_pubkey(<<prefix, x::big-size(256)>> = pubkey)
    when prefix in [2, 3] and x < @crv.p,
    do: pubkey |> from_pubkey() |> validate()

  def parse_pubkey(_pubkey), do: :error

  defp validate(%__MODULE__{point: point} = key) do
    if Point.valid?(point), do: {:ok, key}, else: :error
  end


  @doc """
  Converts the given [`Point`](`Point:t`) to a [`ECDSA Keypair`](`t:t`) struct
  without a private key.
  """
  @spec from_point(Point.t, keyword) :: t
  def from_point(%Point{} = point, opts \\ []) do
    compressed = Keyword.get(opts, :compressed, true)
    %__MODULE__{point: point, compressed: compressed}
  end


  @doc """
  Returns the 32 byte private key binary from the given [`ECDSA Keypair`](`t:t`).
  """
  def to_privkey(%__MODULE__{privkey: privkey}), do: privkey


  @doc """
  Returns the public key binary from the given [`ECDSA Keypair`](`t:t`) in either
  compressed or uncompressed form.

  ## Accepted options

  * `:compressed` - Return a 32 byte compressed public key. Default is `true`.
  """
  def to_pubkey(%__MODULE__{point: %Point{x: x, y: y}, compressed: compressed}, opts \\ []) do
    case Keyword.get(opts, :compressed, compressed) do
      true ->
        prefix = if rem(y, 2) == 0, do: 0x02, else: 0x03
        <<prefix::integer, x::big-size(256)>>
      false ->
        <<4, x::big-size(256), y::big-size(256)>>
    end
  end

end


defimpl Inspect, for: Curvy.Key do
  import Inspect.Algebra

  # Never print the private key: keys end up in logs, crash reports and IEx
  # sessions through inspect/2.
  def inspect(%Curvy.Key{privkey: privkey} = key, opts) do
    fields = [crv: key.crv, point: key.point, compressed: key.compressed]
    fields = if is_nil(privkey), do: fields, else: Keyword.put(fields, :privkey, :redacted)
    concat(["%Curvy.Key", to_doc(Map.new(fields), opts)])
  end
end
