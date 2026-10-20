defmodule BitblocksWeb.RpcStub do
  @moduledoc """
  Manages RPC stub state for tests. See `test/support/RPC_TESTING.md`.

  Stubs live in a public named ETS table owned by a long-lived GenServer, so
  they are visible to any process a test spawns (LiveViews, Oban workers run
  inline, Tasks). Tests that install stubs should be `async: false` — the
  table is global.

  Every call the mock receives is also recorded, so tests can assert on what
  was (or wasn't) fetched:

      RpcStub.calls()
      #=> [{:batch_getrawtransaction, [["txid1"], 1]}, ...]
  """

  use GenServer

  @table :bitblocks_rpc_stub
  @fixtures_dir Path.expand("../fixtures/rpc", __DIR__)

  # -- Lifecycle ---------------------------------------------------------------

  @doc """
  Ensures the stub server is running, clears prior stubs and recorded calls,
  and installs the default fixture stubs. Call from a test's `setup`.
  """
  def setup do
    ensure_started()
    clear()
    install_defaults()
    :ok
  end

  @doc "Clears all stubs and recorded calls (leaves the server running)."
  def clear do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Stops the stub server and drops the table."
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc "True when the stub table exists (i.e. `setup/0` ran at least once)."
  def active?, do: :ets.whereis(@table) != :undefined

  # -- Stub installers -----------------------------------------------------------

  def stub_getblockchaininfo(response), do: put({:getblockchaininfo}, response)

  def stub_getblockhash(height, hash \\ nil) do
    put({:getblockhash, height}, hash || generated_hash(height))
  end

  def stub_getblock(hash, verbosity \\ 1, response \\ nil) do
    put({:getblock, hash, verbosity}, response || fixture!("getblock_verbosity_1.json"))
  end

  def stub_getblockheader(hash, response \\ nil) do
    put({:getblockheader, hash}, response || fixture!("getblock_verbosity_1.json"))
  end

  def stub_getrawtransaction(txid, verbose \\ 1, response \\ nil) do
    put({:getrawtransaction, txid, verbose}, response || fixture!("getrawtransaction.json"))
  end

  def stub_batch_getblockhash(heights, hashes) do
    heights
    |> Enum.zip(hashes)
    |> Enum.each(fn {height, hash} -> stub_getblockhash(height, hash) end)
  end

  @doc """
  Stubs each txid for batch fetching. Pass a list of txids (each gets the
  default fixture, with its txid rewritten) or a `txid => response` map.
  A response of `{:error, reason}` marks that txid as failing.
  """
  def stub_batch_getrawtransaction(txids) when is_list(txids) do
    Enum.each(txids, fn txid ->
      response = fixture!("getrawtransaction.json") |> Map.put("txid", txid)
      stub_getrawtransaction(txid, 1, response)
    end)
  end

  def stub_batch_getrawtransaction(responses) when is_map(responses) do
    Enum.each(responses, fn {txid, response} -> stub_getrawtransaction(txid, 1, response) end)
  end

  # -- Lookup / call log (used by BitcoinsvCliMock) -----------------------------

  @doc false
  def lookup(key) do
    if active?() do
      case :ets.lookup(@table, {:stub, key}) do
        [{_, value}] -> {:ok, value}
        [] -> :miss
      end
    else
      :miss
    end
  end

  @doc false
  def record_call(fun, args) do
    if active?() do
      :ets.update_counter(@table, :call_seq, 1, {:call_seq, 0})
      seq = :ets.lookup_element(@table, :call_seq, 2)
      :ets.insert(@table, {{:call, seq}, {fun, args}})
    end

    :ok
  end

  @doc "All calls the mock received since the last `clear/0`, oldest first."
  def calls do
    if active?() do
      @table
      |> :ets.match({{:call, :"$1"}, :"$2"})
      |> Enum.sort_by(&hd/1)
      |> Enum.map(fn [_seq, call] -> call end)
    else
      []
    end
  end

  @doc "Calls to one function only, e.g. `calls(:batch_getrawtransaction)`."
  def calls(fun), do: for({^fun, args} <- calls(), do: args)

  # -- GenServer (table owner) ---------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, nil}
  end

  defp ensure_started do
    case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp put(key, value) do
    ensure_started()
    :ets.insert(@table, {{:stub, key}, value})
    :ok
  end

  defp install_defaults do
    stub_getblockchaininfo(fixture!("getblockchaininfo.json"))

    "getblockhash.json"
    |> fixture!()
    |> Enum.each(fn {"height_" <> height, hash} ->
      stub_getblockhash(String.to_integer(height), hash)
    end)

    block = fixture!("getblock_verbosity_1.json")
    stub_getblock(block["hash"], 1, block)
  end

  defp fixture!(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp generated_hash(height) do
    height
    |> Integer.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
