defmodule BitblocksWeb.RpcStub do
  @moduledoc """
  Test helper for stubbing Bitcoin RPC calls with cached fixture responses.

  This allows tests to run without a live Bitcoin node and provides
  consistent, fast responses.

  ## Usage

  In your test setup:

      setup do
        BitblocksWeb.RpcStub.setup()
        :ok
      end

  Or manually stub specific responses:

      BitblocksWeb.RpcStub.stub_getblockchaininfo(%{
        "blocks" => 100,
        "headers" => 100
      })

  """

  @fixtures_path Path.join([__DIR__, "..", "fixtures", "rpc"])

  @doc """
  Sets up default RPC stubs for all common calls.

  This should be called in test setup to enable stubbed responses.
  """
  def setup do
    # Start the RpcStub Agent to hold stub state
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end

    # Load and set default stubs
    stub_defaults()
    :ok
  end

  @doc """
  Starts the RpcStub GenServer to hold stub state.
  """
  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Stops the RpcStub GenServer.
  """
  def stop do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          Agent.stop(pid)
        else
          :ok
        end
    end
  end

  @doc """
  Clears all stubs and resets to empty state.
  """
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> Agent.update(__MODULE__, fn _ -> %{} end)
    end
  end

  @doc """
  Stub getblockchaininfo response.
  """
  def stub_getblockchaininfo(response \\ nil) do
    response = response || load_fixture("getblockchaininfo.json")
    set_stub(:getblockchaininfo, response)
  end

  @doc """
  Stub getblockhash response for a specific height.
  """
  def stub_getblockhash(height, hash \\ nil) do
    hash = hash || generate_block_hash(height)
    set_stub({:getblockhash, height}, hash)
  end

  @doc """
  Stub getblock response for a specific hash.
  """
  def stub_getblock(hash, verbosity \\ 1, response \\ nil) do
    response = response || load_fixture("getblock_verbosity_#{verbosity}.json")
    set_stub({:getblock, hash, verbosity}, response)
  end

  @doc """
  Stub getblockheader response for a specific hash.
  """
  def stub_getblockheader(hash, verbosity \\ true, response \\ nil) do
    response = response || load_fixture("getblockheader.json")
    set_stub({:getblockheader, hash, verbosity}, response)
  end

  @doc """
  Stub getrawtransaction response for a specific txid.
  """
  def stub_getrawtransaction(txid, verbosity \\ 1, response \\ nil) do
    response = response || load_fixture("getrawtransaction.json")
    set_stub({:getrawtransaction, txid, verbosity}, response)
  end

  @doc """
  Stub batch_getblockhash response for a range of heights.
  """
  def stub_batch_getblockhash(heights, hashes \\ nil) do
    hashes = hashes || Enum.map(heights, &generate_block_hash/1)
    response = Enum.zip(heights, hashes) |> Map.new()
    set_stub({:batch_getblockhash, heights}, {:ok, response})
  end

  @doc """
  Stub batch_getrawtransaction response for a list of txids.
  """
  def stub_batch_getrawtransaction(txids, responses \\ nil) do
    responses = responses || Enum.map(txids, fn _ -> load_fixture("getrawtransaction.json") end)
    response = Enum.zip(txids, responses) |> Map.new()
    set_stub({:batch_getrawtransaction, txids}, {:ok, response})
  end

  @doc """
  Stub getchaintips response.
  """
  def stub_getchaintips(response \\ nil) do
    response =
      response ||
        [
          %{
            "hash" => "mock-main-tip",
            "height" => 100,
            "branchlen" => 0,
            "status" => "active",
            "chainwork" => "0000000000000000000000000000000000000000000000000000000000100000"
          }
        ]

    set_stub(:getchaintips, response)
  end

  @doc """
  Gets a stubbed response for a given RPC call.

  Returns the stubbed response or nil if no stub is set.
  """
  def get_stub(key) do
    case Process.whereis(__MODULE__) do
      nil -> nil
      _pid -> Agent.get(__MODULE__, &Map.get(&1, key))
    end
  end

  # Private functions

  defp set_stub(key, value) do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end

    Agent.update(__MODULE__, &Map.put(&1, key, value))
  end

  defp stub_defaults do
    # Stub getblockchaininfo
    stub_getblockchaininfo()

    # Stub some common block hashes
    stub_getblockhash(0, "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
    stub_getblockhash(100, "000000007bc154e0fa7ea32218a72fe2c1bb9f86cf8c9ebf9a715ed27fdb229a")
    stub_getblockhash(1000, "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09")

    # Stub a common block
    stub_getblock("00000000000000000123456789abcdef00000000000000000123456789abcdef")

    :ok
  end

  defp load_fixture(filename) do
    fixture_path = Path.join(@fixtures_path, filename)

    case File.read(fixture_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp generate_block_hash(height) do
    # Generate a deterministic but fake block hash based on height
    :crypto.hash(:sha256, "block_#{height}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 64)
    |> String.pad_trailing(64, "0")
  end
end
