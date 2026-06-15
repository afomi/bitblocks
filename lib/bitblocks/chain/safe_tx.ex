defmodule Bitblocks.Chain.SafeTx do
  @moduledoc """
  A **total**, size-bounded wrapper around `BSV.Tx.from_binary/2`.

  ## Why this exists

  `BSV.Tx.from_binary/2` is *not* total: on several classes of malformed input
  (empty string, truncated tx, garbage bytes, an oversized varint count) it
  raises `CaseClauseError` rather than returning `{:error, _}`. Every raw-tx
  decode site in bitblocks fed it node- or user-supplied hex inside a plain
  `case`, so a crafted payload could crash the worker or a LiveView (threat T5,
  CWE-20/248 — "uncaught exception from untrusted input"; asset A4 liveness).

  This module is the single chokepoint that makes the decode safe:

    * **Bounded** — rejects hex above a configurable byte ceiling *before*
      handing it to the decoder, so absurd input can't burn CPU/memory
      (CWE-770). The ceiling is on the hex string length.
    * **Total** — wraps the decoder in `try/rescue/catch` so *any* failure,
      including a library raise, becomes a typed `{:error, reason}`. It never
      raises on hostile input — proven by the fuzz battery
      (`safe_tx_test.exs`).

  Returns `{:ok, %BSV.Tx{}}` or `{:error, reason}`. Use this instead of calling
  `BSV.Tx.from_binary/2` directly anywhere the hex crosses a trust boundary.

  ## Configuration

      config :bitblocks, Bitblocks.Chain.SafeTx, max_hex_bytes: 100_000_000
  """

  require Logger

  @default_max_hex_bytes 100_000_000

  @doc """
  Decode hex-encoded transaction bytes into a `%BSV.Tx{}`, totally and bounded.
  """
  @spec from_hex(any()) :: {:ok, BSV.Tx.t()} | {:error, atom()}
  def from_hex(hex) when is_binary(hex) do
    cond do
      hex == "" ->
        {:error, :empty}

      byte_size(hex) > max_hex_bytes() ->
        {:error, :too_large}

      true ->
        decode(hex)
    end
  end

  def from_hex(_), do: {:error, :not_binary}

  # The decoder can either return {:error, _} (its happy "invalid" path) or
  # raise/throw/exit on inputs it doesn't handle gracefully. Normalise all of
  # those into a typed error so callers never see an exception.
  defp decode(hex) do
    try do
      case BSV.Tx.from_binary(hex, encoding: :hex) do
        {:ok, %BSV.Tx{} = tx} -> {:ok, tx}
        {:error, reason} -> {:error, normalize(reason)}
        _other -> {:error, :decode_failed}
      end
    rescue
      _ -> {:error, :decode_raised}
    catch
      _, _ -> {:error, :decode_threw}
    end
  end

  # Keep error reasons as flat atoms; the library returns tuples like
  # {:invalid_encoding, :hex} which we don't want to leak verbatim.
  defp normalize(reason) when is_atom(reason), do: reason
  defp normalize({tag, _}) when is_atom(tag), do: tag
  defp normalize(_), do: :decode_failed

  defp max_hex_bytes do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(:max_hex_bytes, @default_max_hex_bytes)
  end
end
