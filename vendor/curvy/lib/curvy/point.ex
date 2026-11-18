defmodule Curvy.Point do
  @moduledoc """
  Module used for manipulating ECDSA point coordinates.
  """
  import Bitwise
  import Curvy.Util, only: [mod: 2, inv: 2, ipow: 2]
  alias Curvy.{Curve, Key, Signature}

  defstruct [:x, :y]

  @typedoc "Point Coordinates"
  @type t :: %__MODULE__{
    x: integer,
    y: integer
  }

  @typedoc "Jacobian Point Coordiantes"
  @type jacobian :: %{
    x: integer,
    y: integer,
    z: integer
  }

  @crv Curve.secp256k1


  @doc """
  Converts the signature to a [`Point`](`t:t`) using the given hash integer and
  recovery ID.
  """
  @spec from_signature(Signature.t, integer, Signature.recovery_id) :: t | :error
  def from_signature(%Signature{r: r, s: s}, _e, _recid)
    when r == 0 or s == 0,
    do: :error

  def from_signature(%Signature{r: r, s: s}, e, recid) do
    rinv = inv(r, @crv.n)
    prefix = 2 + band(recid, 1)

    sp = <<prefix, r::big-size(256)>>
    |> Key.from_pubkey()
    |> Map.get(:point)
    |> mul(s)

    hg = @crv[:G]
    |> mul(e)
    |> negate()

    sp
    |> add(hg)
    |> mul(rinv)
  end


  @doc """
  Returns true when the point is a valid, finite point on secp256k1: both
  coordinates are integers in `0..p-1` and `y^2 = x^3 + 7 (mod p)`.

  The point at infinity (`x: 0, y: 0`) and off-curve points are not valid.
  Check public keys from untrusted input with this before using them.
  """
  @spec valid?(t | any) :: boolean
  def valid?(%__MODULE__{x: x, y: y})
    when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 and x < @crv.p and y < @crv.p,
    do: mod(y * y - (x * x * x + @crv.b), @crv.p) == 0

  def valid?(_point), do: false


  @doc """
  Returns true when the point is the point at infinity, as this module
  represents it (`y: 0`).
  """
  @spec infinity?(t) :: boolean
  def infinity?(%__MODULE__{y: 0}), do: true
  def infinity?(%__MODULE__{}), do: false


  @doc """
  Adds two elliptic curve points.

  Returns a [`Point`](`t:t`).
  """
  @spec add(t, t) :: t
  def add(%__MODULE__{} = point, %__MODULE__{} = other) do
    jacobian_add(to_jacobian(point), to_jacobian(other))
    |> from_jacobian()
  end


  @doc """
  Doubles an elliptic curve point.

  Returns a [`Point`](`t:t`).
  """
  @spec double(t) :: t
  def double(%__MODULE__{} = point) do
    point
    |> to_jacobian()
    |> jacobian_double()
    |> from_jacobian()
  end


  @doc """
  Compares two elliptic curve points.

  Returns a `t:boolean`.
  """
  @spec equals(point :: t, other :: t) :: boolean
  def equals(%__MODULE__{} = p, %__MODULE__{} = q) do
    p.x == q.x and p.y == q.y
  end


  @doc """
  Mutiplies an elliptic curve point with the given scalar.

  Returns a [`Point`](`t:t`).
  """
  @spec mul(t, integer) :: t
  def mul(%__MODULE__{} = point, scalar) do
    point
    |> to_jacobian()
    |> jacobian_mul(scalar)
    |> from_jacobian()
  end


  @doc """
  Flips the elliptic curve point to `(x, -y)`.

  Returns a [`Point`](`t:t`).
  """
  @spec negate(point :: t) :: t
  def negate(%__MODULE__{x: x, y: y}),
    do: %__MODULE__{x: x, y: mod(-y, @crv.p)}


  @doc """
  Subtracts the second elliptic curve point from the first.

  Returns a [`Point`](`t:t`).
  """
  @spec subtract(t, t) :: t
  def subtract(%__MODULE__{} = point, %__MODULE__{} = other),
    do: add(point, negate(other))


  # Converts the Point to Jacobian Point Coordianets
  defp to_jacobian(%__MODULE__{x: x, y: y}), do: %{x: x, y: y, z: 1}


  # Converts the Jacobian Point to Affine Coordiantes
  defp from_jacobian(%{x: x, y: y, z: z}) do
    z = inv(z, @crv.p)
    %__MODULE__{
      x: (x * ipow(z, 2)) |> mod(@crv.p),
      y: (y * ipow(z, 3)) |> mod(@crv.p)
    }
  end


  # Fast way to add two elliptic curve points.
  # y = 0 is the point at infinity (secp256k1 has no point of order 2), the
  # identity: infinity + Q = Q and P + infinity = P.
  defp jacobian_add(%{y: 0}, %{} = q), do: q
  defp jacobian_add(%{} = p, %{y: 0}), do: p
  defp jacobian_add(%{} = p, %{} = q) do
    u1 = (p.x * ipow(q.z, 2)) |> mod(@crv.p)
    u2 = (q.x * ipow(p.z, 2)) |> mod(@crv.p)
    s1 = (p.y * ipow(q.z, 3)) |> mod(@crv.p)
    s2 = (q.y * ipow(p.z, 3)) |> mod(@crv.p)

    cond do
      u1 == u2 and s1 != s2 ->
        %{x: 0, y: 0, z: 1}

      u1 == u2 ->
        jacobian_double(p)

      true ->
        h = u2 - u1
        r = s2 - s1
        h2 = mod(h * h, @crv.p)
        h3 = mod(h * h2, @crv.p)
        u1h2 = mod(u1 * h2, @crv.p)
        x = (ipow(r, 2) - h3 - 2 * u1h2) |> mod(@crv.p)
        y = (r * (u1h2 - x) - s1 * h3) |> mod(@crv.p)
        z = (h * p.z * q.z) |> mod(@crv.p)
        %{x: x, y: y, z: z}
    end
  end


  # Fast way to doubles an elliptic curve point
  defp jacobian_double(%{y: 0}), do: %{x: 0, y: 0, z: 0}
  defp jacobian_double(%{} = p) do
    ysq = ipow(p.y, 2) |> mod(@crv.p)
    s = (4 * p.x * ysq) |> mod(@crv.p)
    m = (3 * ipow(p.x, 2) + @crv.a * ipow(p.z, 4)) |> mod(@crv.p)
    x = (ipow(m, 2) - 2 * s) |> mod(@crv.p)
    y = (m * (s - x) - 8 * ipow(ysq, 2)) |> mod(@crv.p)
    z = (2 * p.y * p.z) |> mod(@crv.p)
    %{x: x, y: y, z: z}
  end


  # Fast way to multiply the point with a scalar
  defp jacobian_mul(%{}, 0), do: %{x: 0, y: 0, z: 1}
  defp jacobian_mul(%{y: 0}, s) when s == 1, do: %{x: 0, y: 0, z: 1}
  defp jacobian_mul(%{} = p, s) when s == 1, do: p
  defp jacobian_mul(%{y: 0}, s) when s < 0 or @crv.n <= s, do: %{x: 0, y: 0, z: 1}
  defp jacobian_mul(%{} = p, s) when s < 0 or @crv.n <= s, do: jacobian_mul(p, mod(s, @crv.n))
  defp jacobian_mul(%{y: 0}, s) when rem(s, 2) == 0, do: %{x: 0, y: 0, z: 1}
  defp jacobian_mul(%{} = p, s) when rem(s, 2) == 0, do: jacobian_mul(p, div(s, 2)) |> jacobian_double()
  defp jacobian_mul(%{y: 0}, _s), do: %{x: 0, y: 0, z: 1}
  defp jacobian_mul(%{} = p, s), do: jacobian_mul(p, div(s, 2)) |> jacobian_double() |> jacobian_add(p)

end
