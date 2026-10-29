defmodule Bitblocks.Woc do
  @moduledoc """
  WhatsOnChain as a fallback tx source, for targeted imports while our node is
  down or behind (#30). Nothing here is trusted on WoC's word alone: imported
  bodies are checked against their txids by `Chain.TxIngest`, and membership
  and ownership are derived from those bytes.

  Free tier: about 3 requests a second. Calls are spaced by `:interval_ms` and
  a 429 is retried after a pause. The client is swapped in tests via
  `config :bitblocks, :woc_client`.
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
    @interval_ms 400

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
      Process.sleep(@interval_ms)
      headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
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

    defp decode(resp) do
      case Jason.decode(resp) do
        {:ok, decoded} -> decoded
        _ -> resp
      end
    end
  end
end
