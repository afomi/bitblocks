defmodule Bitblocks.Payments.Bsv402Test do
  @moduledoc """
  The BSV 402 verifier, no HTTP (docs/BSV_402.md, slice 1): every published
  vector (`priv/data/interop/bsv402_v0.json`) gives its stated answer through
  `Bsv402.verify/3`, with the file's key, price, clock and headers and a
  stubbed node; the derivation matches `@bsv/sdk`'s; the configuration says
  what is missing without saying any value.
  """
  # async: false: the env var the identity key is read from is global.
  use Bitblocks.DataCase, async: false

  @moduletag :capture_log

  alias Bitblocks.Interop.{Brc42, Bsv402Vectors}
  alias Bitblocks.Payments.{Bsv402, BsvPayment}
  alias Bitblocks.Repo
  alias BitblocksWeb.RpcStub

  @doc_map Jason.decode!(Bsv402Vectors.body())
  @vectors @doc_map["vectors"]
  @sdk Path.expand("../../support/fixtures/brc/bsv402_brc29_sdk.json", __DIR__)
       |> File.read!()
       |> Jason.decode!()

  defp unhex(hex), do: Base.decode16!(hex, case: :mixed)

  # The file's headers, as `Chain.Headers` gives one we'd rely on.
  @held Map.new(@doc_map["headers"], fn header ->
          {header["height"],
           %{
             hash: "synthetic",
             merkleroot: header["merkleroot"],
             num_tx: header["tx_count"],
             verified: true,
             canonical: true
           }}
        end)

  defp node_answer("accept"), do: :accepted
  defp node_answer("already_known"), do: :already_known
  defp node_answer("unreachable"), do: :unavailable
  defp node_answer("reject:" <> reason), do: {:rejected, reason}

  defp request(%{"method" => method, "path" => path, "query" => query}),
    do: %{method: method, path: path, query: query}

  defp opts(vector, extra \\ []) do
    test = self()
    answer = node_answer(vector["node"])

    Keyword.merge(
      [
        identity: Bsv402.identity_from(unhex(@doc_map["server"]["identity_private_key"])),
        price: @doc_map["price_sats"],
        now_ms: @doc_map["now_ms"],
        max_beef_bytes: @doc_map["max_beef_bytes"],
        headers: fn heights -> Map.take(@held, heights) end,
        tip: @held |> Map.keys() |> Enum.max(),
        broadcast: fn raw ->
          send(test, {:broadcast, raw})
          answer
        end
      ],
      extra
    )
  end

  defp claim!(txid, request) do
    Repo.insert!(%BsvPayment{
      txid: txid,
      vout: 0,
      satoshis: @doc_map["price_sats"],
      sender_key: @doc_map["sender"]["identity_key"],
      derivation_prefix: "x",
      derivation_suffix: "x",
      raw_tx: <<0>>,
      request_hash: Bsv402.request_hash(request["method"], request["path"], request["query"]),
      price_sats: @doc_map["price_sats"],
      caller: @doc_map["sender"]["identity_key"],
      accepted_at: DateTime.utc_now()
    })
  end

  defp run(vector, extra \\ []) do
    for %{"txid" => txid, "request" => request} <- vector["claimed"], do: claim!(txid, request)
    Bsv402.verify(vector["payment"], request(vector["request"]), opts(vector, extra))
  end

  defp vector(id), do: Enum.find(@vectors, &(&1["id"] == id))

  describe "the published vectors" do
    for vector <- @vectors do
      @vector vector
      test "#{vector["id"]}: #{vector["case"]}" do
        vector = @vector
        expected = vector["expected"]
        claimed_before = Repo.aggregate(BsvPayment, :count)

        case run(vector) do
          {:ok, paid} ->
            assert expected["status"] == 200, vector["id"]
            assert Atom.to_string(paid.outcome) == expected["outcome"]
            assert paid.txid == vector["txid"]
            assert paid.sender_key == vector["payment"]["x-bsv-sender"]

            if paid.outcome == :reserved do
              refute_received {:broadcast, _}
            else
              assert_received {:broadcast, _raw}
              assert Repo.get_by!(BsvPayment, txid: paid.txid).status == "accepted"
            end

          {:error, refused} ->
            assert refused.status == expected["status"], vector["id"]
            assert expected["outcome"] == "refused"
            assert Atom.to_string(refused.reason) == expected["reason"], vector["id"]
            assert refused.detail == Bsv402.detail(refused.reason)

            # A refusal leaves no new claim behind, even one the node refused.
            assert Repo.aggregate(BsvPayment, :count) ==
                     claimed_before + length(vector["claimed"])
        end
      end
    end

    test "the script builds exactly what's published" do
      {doc, _binding} = Code.eval_file("scripts/bsv402_vectors_v0.exs")

      assert doc |> Jason.encode!() |> Jason.decode!() == @doc_map
    end

    test "cover every reason the verifier gives, apart from the database's own" do
      reasons = @vectors |> Enum.map(& &1["expected"]["reason"]) |> MapSet.new()

      for reason <- ~w(incomplete malformed too_large stale replayed not_our_output underpaid
                       unproven unknown_block broadcast_rejected broadcast_unavailable) do
        assert reason in reasons, reason
      end
    end

    test "the keys are the file's own, made from labels" do
      label = fn text -> :crypto.hash(:sha256, "bitblocks bsv402 vectors v0: " <> text) end

      assert unhex(@doc_map["server"]["identity_private_key"]) == label.("server")
      assert unhex(@doc_map["sender"]["identity_private_key"]) == label.("sender")
      assert @doc_map["claim"] =~ "unsigned"
      assert @doc_map["tried_against"] =~ "No live wallet"
    end
  end

  describe "a payment, once" do
    test "is claimed once, and its replay for another request is refused" do
      vector = vector("pays-exact")
      assert {:ok, %{outcome: :accepted} = paid} = run(vector)

      row = Repo.get_by!(BsvPayment, txid: paid.txid)
      assert row.satoshis == @doc_map["price_sats"]
      assert row.price_sats == @doc_map["price_sats"]
      assert row.sender_key == @doc_map["sender"]["identity_key"]
      assert row.caller == row.sender_key
      assert row.derivation_prefix == vector["payment"]["x-bsv-nonce"]
      assert row.derivation_suffix == Base.encode64(vector["payment"]["x-bsv-time"])
      assert row.envelope == "brc121"

      other = %{method: "GET", path: "/api/v1/blocks/1", query: ""}

      assert {:error, %{reason: :replayed, status: 402}} =
               Bsv402.verify(vector["payment"], other, opts(vector))

      # The same request again, inside the window: served, not charged twice.
      assert {:ok, %{outcome: :reserved}} =
               Bsv402.verify(vector["payment"], request(vector["request"]), opts(vector))

      assert Repo.aggregate(BsvPayment, :count) == 1
    end

    test "refused by the node is not claimed, and can be sent again" do
      vector = vector("node-rejects")
      assert {:error, %{reason: :broadcast_rejected}} = run(vector)
      assert {:ok, %{outcome: :accepted}} = run(vector, broadcast: fn _ -> :accepted end)
    end
  end

  describe "the derivation" do
    test "matches @bsv/sdk's for the vectors' keys" do
      for c <- @sdk["cases"] do
        server =
          if c["server"] == "server",
            do: unhex(@doc_map["server"]["identity_private_key"]),
            else: :crypto.hash(:sha256, "bitblocks bsv402 vectors v0: other server")

        assert Base.encode16(Brc42.public_key(server), case: :lower) == c["server_identity_key"]
        assert c["key_id"] == "#{c["derivation_prefix"]} #{Bsv402.suffix(c["time"])}"

        {:ok, child} =
          Brc42.private_child(
            server,
            unhex(c["sender_identity_key"]),
            Bsv402.invoice(c["derivation_prefix"], c["time"])
          )

        assert Base.encode16(Brc42.public_key(child), case: :lower) == c["derived_public_key"]
      end
    end

    test "the suffix is the base64 of the time's text, as @bsv/402-pay sends it" do
      assert Bsv402.suffix("1764000000000") == "MTc2NDAwMDAwMDAwMA=="
    end
  end

  describe "the node" do
    setup do
      RpcStub.setup()
      on_exit(&RpcStub.clear/0)
    end

    test "a txid back is taken" do
      RpcStub.stub_sendrawtransaction(String.duplicate("ab", 32))
      assert Bsv402.broadcast(<<1, 2>>) == :accepted
      assert RpcStub.calls(:sendrawtransaction) == [["0102"]]
    end

    test "already known, in the mempool or a block, is taken" do
      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -26, "message" => "257: txn-already-known"}}
      )

      assert Bsv402.broadcast(<<1>>) == :already_known

      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -27, "message" => "Transaction already in block chain"}}
      )

      assert Bsv402.broadcast(<<1>>) == :already_known
    end

    test "a refusal carries the node's reason" do
      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -26, "message" => "258: txn-mempool-conflict"}}
      )

      assert Bsv402.broadcast(<<1>>) == {:rejected, "258: txn-mempool-conflict"}
    end

    test "no answer, or a node warming up, is unavailable" do
      RpcStub.stub_sendrawtransaction({:error, {:connection_error, :econnrefused}})
      assert Bsv402.broadcast(<<1>>) == :unavailable

      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -28, "message" => "Loading block index..."}}
      )

      assert Bsv402.broadcast(<<1>>) == :unavailable
    end
  end

  describe "configuration" do
    setup do
      config = Application.get_env(:bitblocks, Bsv402)
      env = System.get_env("BSV402_TEST_IDENTITY_KEY")

      on_exit(fn ->
        if config,
          do: Application.put_env(:bitblocks, Bsv402, config),
          else: Application.delete_env(:bitblocks, Bsv402)

        if env,
          do: System.put_env("BSV402_TEST_IDENTITY_KEY", env),
          else: System.delete_env("BSV402_TEST_IDENTITY_KEY")
      end)
    end

    defp configure(opts) do
      Application.put_env(
        :bitblocks,
        Bsv402,
        Keyword.merge([identity_key_env: "BSV402_TEST_IDENTITY_KEY"], opts)
      )
    end

    test "off by default, and the 402 carries no terms" do
      configure(enabled: false, price_sats: "100")
      System.put_env("BSV402_TEST_IDENTITY_KEY", @doc_map["server"]["identity_private_key"])

      refute Bsv402.enabled?()
      assert Bsv402.status() == :disabled
      assert Bsv402.terms() == []
    end

    test "enabled without a key or a price stays off, and names what's missing, never a value" do
      System.delete_env("BSV402_TEST_IDENTITY_KEY")
      configure(enabled: true, price_sats: nil)

      refute Bsv402.enabled?()
      assert Bsv402.status() == :no_identity_key
      missing = Enum.join(Bsv402.missing(), "\n")
      assert missing =~ "BSV402_TEST_IDENTITY_KEY is not set"
      assert missing =~ "BSV402_PRICE_SATS is not set"
      assert Bsv402.terms() == []

      System.put_env("BSV402_TEST_IDENTITY_KEY", "not a key")
      assert Bsv402.status() == :invalid_identity_key
      refute Enum.join(Bsv402.missing(), "\n") =~ "not a key"

      System.put_env("BSV402_TEST_IDENTITY_KEY", @doc_map["server"]["identity_private_key"])
      assert Bsv402.status() == :no_price
      configure(enabled: true, price_sats: "0")
      assert Bsv402.status() == :no_price
    end

    test "on, the terms are the price and our public key" do
      System.put_env("BSV402_TEST_IDENTITY_KEY", @doc_map["server"]["identity_private_key"])
      configure(enabled: true, price_sats: "100")

      assert Bsv402.enabled?()
      assert Bsv402.missing() == []

      assert Bsv402.terms() == [
               {"x-bsv-sats", "100"},
               {"x-bsv-server", @doc_map["server"]["identity_key"]}
             ]
    end

    test "the identity key never shows in inspect" do
      key = Bsv402.identity_from(unhex(@doc_map["server"]["identity_private_key"]))
      shown = inspect(key)

      assert shown =~ @doc_map["server"]["identity_key"]
      refute shown =~ @doc_map["server"]["identity_private_key"]
    end
  end
end
