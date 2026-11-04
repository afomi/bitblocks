defmodule Bitblocks.NextBlock do
  @moduledoc """
  The block after our newest header, for the row above /blocks, and what is
  known about it:

    * `:on_chain`: mined, and our node has verified it; `num_tx` is from the
      node's header.
    * `:node_verifying`: mined (the node has its header), but the node
      hasn't verified it yet, so it can't name it; no count.
    * `:assembling`: we're at the network tip; `num_tx` is the node's
      mempool size (nil if the node keeps no mempool, e.g. `blocksonly=1`).
    * `:unknown`: the node isn't answering.

  `info/1` is cached for 30 seconds, so page views never reach the node.
  """

  alias Bitblocks.RpcCache

  @ttl_ms 30_000

  @doc "What is known about the block after `latest`, cached."
  def info(latest) when is_integer(latest) do
    key = {__MODULE__, latest}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {at, value} when now - at < @ttl_ms ->
        value

      _ ->
        value = info(latest, live_facts())
        :persistent_term.put(key, {now, value})
        value
    end
  end

  def info(nil), do: %{height: nil, state: :unknown, num_tx: nil}

  @doc false
  # From given facts (for tests): the node's blockchain info, and functions
  # for a header at a height and the mempool, called only when needed.
  def info(latest, %{node: node} = facts) do
    next = latest + 1

    case node do
      %{"blocks" => blocks, "headers" => headers} when headers >= next and blocks >= next ->
        %{height: next, state: :on_chain, num_tx: field(facts.header.(next), "num_tx")}

      %{"headers" => headers} when headers >= next ->
        %{height: next, state: :node_verifying, num_tx: nil}

      %{"headers" => _} ->
        %{height: next, state: :assembling, num_tx: field(facts.mempool.(), "size")}

      _ ->
        %{height: next, state: :unknown, num_tx: nil}
    end
  end

  defp field({:ok, %{} = map}, key), do: positive(map[key])
  defp field(%{} = map, key), do: positive(map[key])
  defp field(_, _), do: nil

  defp positive(n) when is_integer(n) and n >= 0, do: n
  defp positive(_), do: nil

  defp live_facts do
    %{
      node: safe(fn -> RpcCache.get_blockchain_info() end),
      header: fn height ->
        safe(fn ->
          with hash when is_binary(hash) <- cli().getblockhash(height),
               %{} = header <- cli().getblockheader(hash, true),
               do: {:ok, header}
        end)
      end,
      mempool: fn -> safe(fn -> cli().getmempoolinfo() end) end
    }
  end

  defp cli, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
