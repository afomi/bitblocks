defmodule Bitblocks.Woc do
  @moduledoc """
  WhatsOnChain as a fallback tx source, for targeted imports while our node is
  down or behind (#30). Nothing here is trusted on WoC's word alone: imported
  bodies are checked against their txids by `Chain.TxIngest`, and membership
  and ownership are derived from those bytes.

  It is also the historical source for block sync while our own node is down
  and PublicNode is pruned: `block_txids/1` supplies a block's txid list,
  which `Chain.TxidSource` merkleroot-verifies against the PoW header before
  anything is fetched (fail closed), and `txs/1` supplies the bodies.

  Free tier: about 3 requests a second, no key. With `WOC_API_KEY` set the
  key is sent as the `Authorization` header and `WOC_RPS` (default 10) sets
  the pace; paid plans are 10, 20 or 40 requests a second. Calls are spaced
  by the configured interval and a 429 is retried after a pause. The client
  is swapped in tests via `config :bitblocks, :woc_client`.
  """

  # WoC caps bulk tx lookups at 20 txids per request.
  @bulk 20

  @doc "Bulk size for `txs/1`."
  def bulk_size, do: @bulk

  @doc """
  Up to 20 txs as getrawtransaction-style maps (`txid`, `hex`, `vin`, `vout`,
  `blockhash`, `blockheight`). WoC splits the decoded JSON and the hex across
  two endpoints, so this merges them by txid.
  """
  @spec txs([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def txs(txids) when length(txids) <= @bulk, do: client().txs(txids)

  @doc """
  A block's full txid list, in block order: the first 100 txids from
  `/block/hash/:hash`, then its 50,000-txid pages. Unverified: callers must
  check it against the header merkleroot (`Chain.TxidSource` does).
  """
  @spec block_txids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def block_txids(hash), do: client().block_txids(hash)

  @doc """
  The input spending `txid:vout`: `{:ok, %{txid, vin}}`, `{:ok, :unspent}`, or
  `{:error, reason}`.
  """
  @spec spent(String.t(), non_neg_integer()) ::
          {:ok, %{txid: String.t(), vin: non_neg_integer()} | :unspent} | {:error, term()}
  def spent(txid, vout), do: client().spent(txid, vout)

  defp client, do: Application.get_env(:bitblocks, :woc_client, __MODULE__.HTTP)

  defmodule HTTP do
    @moduledoc false

    require Logger

    @base "https://api.whatsonchain.com/v1/bsv/main"

    def txs(txids) do
      body = Jason.encode!(%{txids: txids})

      with {:ok, json} <- post("/txs", body),
           {:ok, hex} <- post("/txs/hex", body) do
        hex_by_txid = Map.new(hex, &{&1["txid"], &1["hex"]})

        {:ok,
         for tx <- json, is_map(tx), hex_by_txid[tx["txid"]] do
           tx
           |> Map.put("hex", hex_by_txid[tx["txid"]])
           |> Map.put("height", tx["blockheight"])
         end}
      end
    end

    def block_txids(hash) do
      case request(:get, "/block/hash/#{hash}", "") do
        {:ok, 200, %{"hash" => ^hash, "tx" => first} = block} when is_list(first) ->
          pages = get_in(block, ["pages", "uri"]) || []

          Enum.reduce_while(pages, {:ok, [first]}, fn uri, {:ok, acc} ->
            case request(:get, uri, "") do
              {:ok, 200, page} when is_list(page) -> {:cont, {:ok, [page | acc]}}
              {:ok, status, body} -> {:halt, {:error, {:http_status, status, body}}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> Enum.concat()}
            error -> error
          end

        {:ok, 404, _} ->
          {:error, :not_found}

        {:ok, status, body} ->
          {:error, {:http_status, status, body}}

        error ->
          error
      end
    end

    def spent(txid, vout) do
      case request(:get, "/tx/#{txid}/#{vout}/spent", "") do
        {:ok, 200, %{"txid" => spender, "vin" => vin}} -> {:ok, %{txid: spender, vin: vin}}
        {:ok, 404, _} -> {:ok, :unspent}
        {:ok, status, body} -> {:error, {:http_status, status, body}}
        error -> error
      end
    end

    defp post(path, body) do
      case request(:post, path, body) do
        {:ok, 200, list} when is_list(list) -> {:ok, list}
        {:ok, status, body} -> {:error, {:http_status, status, body}}
        error -> error
      end
    end

    defp request(method, path, body, attempt \\ 1) do
      Process.sleep(interval_ms())
      headers = [{"content-type", "application/json"}, {"accept", "application/json"}] ++ auth()
      opts = [timeout: 10_000, recv_timeout: 60_000]

      case HTTPoison.request(method, @base <> path, body, headers, opts) do
        {:ok, %HTTPoison.Response{status_code: 429}} when attempt < 5 ->
          Logger.warning("WoC 429 on #{path}; backing off (attempt #{attempt})")
          Process.sleep(2_000 * attempt)
          request(method, path, body, attempt + 1)

        {:ok, %HTTPoison.Response{status_code: status, body: resp}} ->
          {:ok, status, decode(resp)}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, reason}
      end
    end

    defp config, do: Application.get_env(:bitblocks, Bitblocks.Woc, [])

    defp auth do
      case config()[:api_key] do
        key when is_binary(key) and key != "" -> [{"authorization", key}]
        _ -> []
      end
    end

    # Free tier is ~3 req/s; 400 ms keeps a single caller under it. A key's
    # plan sets its own pace via :rps.
    defp interval_ms do
      case config()[:rps] do
        rps when is_integer(rps) and rps > 0 -> div(1_000, rps) + 1
        _ -> 400
      end
    end

    defp decode(resp) do
      case Jason.decode(resp) do
        {:ok, decoded} -> decoded
        _ -> resp
      end
    end
  end
end
