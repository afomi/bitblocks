defmodule BitblocksWeb.Api.BeefController do
  @moduledoc """
  `POST /api/v1/beef/verify`: checks a BEEF from anyone against the headers we
  hold (`Bitblocks.Chain.BeefVerifier`). A verifier's answer is a 200 whatever
  the evidence shows, so read `data.status`. The claim is inclusion in a block.

  The body is the BEEF: raw bytes as `application/octet-stream`, or
  `{"beef": "<hex>"}` as `application/json`.

    * 400: `beef` is missing or isn't hex;
    * 413: the BEEF is over the limit (`:beef_verify_max_bytes`);
    * 415: any other content type;
    * 422: the bytes aren't a BEEF we can read, with `reason`.

  ## The size limit

  The endpoint's `Plug.Parsers` passes `application/octet-stream` through
  unread, so that body is read here and only here, after the key-or-session
  gate, up to the limit. A JSON body is read by the parser ahead of the router,
  which caps it at its own default of 8 MB and raises a 413 past that; the hex
  it holds is then held to the same limit as raw bytes.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.BeefVerifier

  @max_bytes 4_000_000
  @read_length 1_000_000

  @doc "POST /api/v1/beef/verify"
  def verify(conn, _params) do
    with {:ok, bytes, conn} <- body(conn),
         {:ok, answer} <- BeefVerifier.verify(bytes, max_bytes: max_bytes()) do
      json(conn, %{data: answer})
    else
      {:error, :too_large} -> too_large(conn)
      {:refused, status, message} -> error(conn, status, message)
      {:error, reason} when is_atom(reason) -> unreadable(conn, reason)
    end
  end

  defp body(conn) do
    case content_type(conn) do
      "application/octet-stream" -> raw_body(conn)
      "application/json" -> hex_body(conn)
      _ -> {:refused, 415, "Send the BEEF as application/octet-stream or application/json"}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp raw_body(conn) do
    limit = max_bytes()

    if declared_length(conn) > limit do
      {:error, :too_large}
    else
      case read_body(conn, length: limit, read_length: min(limit, @read_length)) do
        {:ok, bytes, conn} when byte_size(bytes) <= limit -> {:ok, bytes, conn}
        {:ok, _bytes, _conn} -> {:error, :too_large}
        {:more, _bytes, _conn} -> {:error, :too_large}
        {:error, _reason} -> {:refused, 400, "The request body could not be read"}
      end
    end
  end

  defp declared_length(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end

  # body_params, not params: a BEEF comes in the body, never in the query string.
  defp hex_body(%{body_params: %{"beef" => hex}} = conn) when is_binary(hex) do
    if byte_size(hex) > max_bytes() * 2 do
      {:error, :too_large}
    else
      case Base.decode16(hex, case: :mixed) do
        {:ok, bytes} -> {:ok, bytes, conn}
        :error -> {:refused, 400, "beef must be hex"}
      end
    end
  end

  defp hex_body(_conn), do: {:refused, 400, ~s(Send {"beef": "<hex>"})}

  defp too_large(conn) do
    conn
    |> put_status(413)
    |> json(%{error: "A BEEF can be at most #{max_bytes()} bytes", reason: :too_large})
  end

  defp unreadable(conn, reason) do
    conn
    |> put_status(422)
    |> json(%{error: "These bytes are not a BEEF we can read", reason: reason})
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp max_bytes, do: Application.get_env(:bitblocks, :beef_verify_max_bytes, @max_bytes)
end
