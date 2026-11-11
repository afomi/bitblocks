defmodule Bitblocks.Interop.Jcs do
  @moduledoc """
  RFC 8785 (JSON Canonicalization Scheme) over a restricted value set:
  strings, integers within ±(2^53 - 1), `null`, arrays and objects.

  The set is the one qart's `receipt_v2` and our
  `interop-kit/payment-acceptance/v0` record share (`docs/INTEROP_KIT.md`).
  With no floats and no booleans, RFC 8785's number serializer never runs,
  so two readers agree byte for byte without porting ECMAScript's
  `Number.prototype.toString`.

  Writing (`encode/1`):

  * members sorted by their names' UTF-16 code units (RFC 8785 §3.2.3);
  * strings escaped as ECMAScript's `JSON.stringify` does (§3.2.2.2):
    the two-letter escapes for `"`, `\\`, backspace, tab, newline, form feed
    and carriage return, every other control character as `\\u00xx` in
    lowercase hex, and everything else as itself in UTF-8;
  * integers in plain decimal; no whitespace anywhere.

  Reading (`decode/1`) is strict: it refuses a duplicate member name, any
  value outside the set, and bytes that parse but are not already the
  canonical form of what they hold.

  This is Bitblocks' own reader, written apart from qart's `Qart.JCS`, so the
  two check each other (`test/bitblocks/interop/receipt_v2_vectors_test.exs`).
  """

  @limit 9_007_199_254_740_991

  @type value :: String.t() | integer() | nil | [value()] | %{optional(String.t()) => value()}
  @type reason ::
          :invalid_json
          | :duplicate_key
          | :float
          | :boolean
          | :integer_out_of_range
          | :invalid_string
          | :invalid_value
          | :not_canonical

  @doc "The largest integer magnitude the set holds, 2^53 - 1."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  The canonical bytes of `value`.

  Map keys must be strings. Returns `{:error, reason}` for a value outside
  the set.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, reason()}
  def encode(value) do
    with :ok <- check(value), do: {:ok, IO.iodata_to_binary(write(value))}
  end

  @doc "As `encode/1`, raising on a value outside the set."
  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "not in the restricted JCS set: #{reason}"
    end
  end

  @doc """
  Reads bytes that must already be canonical.

  Returns `{:ok, value}`, with objects as maps, or `{:error, reason}`:
  `:invalid_json`, `:duplicate_key`, a value outside the set (`:float`,
  `:boolean`, `:integer_out_of_range`), or `:not_canonical`.
  """
  @spec decode(binary()) :: {:ok, value()} | {:error, reason()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, tree} <- parse(bytes),
         {:ok, value} <- to_value(tree),
         {:ok, canonical} <- encode(value) do
      if canonical == bytes, do: {:ok, value}, else: {:error, :not_canonical}
    end
  end

  # Ordered objects keep every member, so a repeated name is still visible.
  defp parse(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, tree} -> {:ok, tree}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp to_value(%Jason.OrderedObject{values: members}) do
    names = Enum.map(members, &elem(&1, 0))

    if length(names) == length(Enum.uniq(names)) do
      reduce_ok(members, %{}, fn {name, child}, acc ->
        with {:ok, v} <- to_value(child), do: {:ok, Map.put(acc, name, v)}
      end)
    else
      {:error, :duplicate_key}
    end
  end

  defp to_value(list) when is_list(list) do
    with {:ok, reversed} <-
           reduce_ok(list, [], fn child, acc ->
             with {:ok, v} <- to_value(child), do: {:ok, [v | acc]}
           end),
         do: {:ok, Enum.reverse(reversed)}
  end

  defp to_value(scalar), do: {:ok, scalar}

  defp reduce_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  # Checked first, so writing never meets a value it can't hold.
  defp check(nil), do: :ok
  defp check(v) when is_boolean(v), do: {:error, :boolean}
  defp check(v) when is_float(v), do: {:error, :float}
  defp check(v) when is_integer(v) and v >= -@limit and v <= @limit, do: :ok
  defp check(v) when is_integer(v), do: {:error, :integer_out_of_range}

  defp check(v) when is_binary(v),
    do: if(String.valid?(v), do: :ok, else: {:error, :invalid_string})

  defp check(v) when is_list(v), do: check_all(v)

  defp check(v) when is_map(v) and not is_struct(v) do
    if Enum.all?(Map.keys(v), &(is_binary(&1) and String.valid?(&1))),
      do: check_all(Map.values(v)),
      else: {:error, :invalid_value}
  end

  defp check(_v), do: {:error, :invalid_value}

  defp check_all(values) do
    Enum.reduce_while(values, :ok, fn v, :ok ->
      case check(v) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write(nil), do: "null"
  defp write(v) when is_integer(v), do: Integer.to_string(v)
  defp write(v) when is_binary(v), do: quote_string(v)
  defp write(v) when is_list(v), do: [?[, Enum.intersperse(Enum.map(v, &write/1), ?,), ?]]

  defp write(v) when is_map(v) do
    members =
      v
      |> Enum.sort_by(fn {name, _} -> :unicode.characters_to_binary(name, :utf8, :utf16) end)
      |> Enum.map(fn {name, child} -> [quote_string(name), ?:, write(child)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp quote_string(s), do: [?", for(<<c::utf8 <- s>>, do: escape(c)), ?"]

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(0x08), do: "\\b"
  defp escape(0x09), do: "\\t"
  defp escape(0x0A), do: "\\n"
  defp escape(0x0C), do: "\\f"
  defp escape(0x0D), do: "\\r"

  defp escape(c) when c < 0x20,
    do: "\\u" <> String.pad_leading(Integer.to_string(c, 16) |> String.downcase(), 4, "0")

  defp escape(c), do: <<c::utf8>>
end
