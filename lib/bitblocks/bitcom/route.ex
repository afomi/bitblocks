defmodule Bitblocks.Bitcom.Route do
  @moduledoc """
  bit:// route matching and endpoint templates (Bitcom `0.1.0.md`).

  Matchers follow the route-parser rules Bitcom adopted
  (https://github.com/rcs/route-parser):

    * `:name` captures up to `/`, `?`, or the end
    * `*name` (splat) captures up to `?` or the end
    * `( … )` is optional and may nest
    * anything else is a literal

  Endpoint templates substitute captures as `${name}`:
  `https://media.bitcoinfiles.org/${tx}`.
  """

  @doc """
  Matches `path` against `matcher`. Returns `{:ok, captures}` (string keys) or
  `:nomatch`; an unparseable matcher never matches.
  """
  @spec match(String.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | :nomatch
  def match(matcher, path) when is_binary(matcher) and is_binary(path) do
    with {:ok, regex} <- compile(matcher),
         %{} = captures <- Regex.named_captures(regex, path) do
      {:ok, Map.reject(captures, fn {_name, value} -> value == "" end)}
    else
      _ -> :nomatch
    end
  end

  @doc "Instantiates an endpoint template with captures (missing ones become empty)."
  @spec instantiate(String.t(), map()) :: String.t()
  def instantiate(template, captures) when is_binary(template) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, template, fn _, name ->
      captures |> Map.get(name, "") |> URI.encode()
    end)
  end

  @doc "Compiles a matcher to an anchored regex."
  @spec compile(String.t()) :: {:ok, Regex.t()} | :error
  def compile(matcher) when is_binary(matcher) do
    with {:ok, source, 0} <- translate(matcher, "", 0),
         {:ok, regex} <- Regex.compile("\\A" <> source <> "\\z") do
      {:ok, regex}
    else
      _ -> :error
    end
  end

  # Walks the matcher once; `depth` tracks open optional groups.
  defp translate("", acc, depth), do: {:ok, acc, depth}

  defp translate("(" <> rest, acc, depth), do: translate(rest, acc <> "(?:", depth + 1)

  defp translate(")" <> _rest, _acc, 0), do: :error
  defp translate(")" <> rest, acc, depth), do: translate(rest, acc <> ")?", depth - 1)

  defp translate(":" <> rest, acc, depth), do: capture(rest, acc, depth, "[^/?]+")
  defp translate("*" <> rest, acc, depth), do: capture(rest, acc, depth, "[^?]+")

  defp translate(<<char::utf8, rest::binary>>, acc, depth),
    do: translate(rest, acc <> Regex.escape(<<char::utf8>>), depth)

  defp capture(rest, acc, depth, pattern) do
    case Regex.run(~r/\A[A-Za-z_][A-Za-z0-9_]*/, rest) do
      [name] ->
        translate(
          binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name)),
          acc <> "(?<#{name}>#{pattern})",
          depth
        )

      nil ->
        :error
    end
  end
end
