defmodule Bitblocks.CloudQuoteTest do
  @moduledoc """
  The cloud services quote request (https://github.com/afomi/bitblocks/issues/113):
  a filter read the way the projection API takes it, and a bounded estimate
  over the blocks held complete.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Bitcom.Command
  alias Bitblocks.CloudQuote
  alias Bitblocks.Projections.Projection

  @addr "1DonationAddressXXXXXXXXXXXXXXXXX"
  @ns "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"

  defp params(overrides) do
    Map.merge(CloudQuote.default_params(), overrides)
  end

  describe "parse/1" do
    test "reads a filter as the projection API takes it, with the same definition hash" do
      assert {:ok, spec} =
               CloudQuote.parse(
                 params(%{
                   "filter" => %{"protocols" => "MAP, AIP\nMAP", "aip_signers" => " #{@addr} "}
                 })
               )

      assert spec.filter == %{"protocols" => ["MAP", "AIP"], "aip_signers" => [@addr]}
      assert spec.definition_hash == Projection.definition_hash(spec.filter)

      assert CloudQuote.filter_json(spec) ==
               ~s({"aip_signers":["#{@addr}"],"protocols":["MAP","AIP"]})
    end

    test "asks for at least one value, except for a dedicated instance" do
      assert {:error, [message]} = CloudQuote.parse(params(%{}))
      assert message =~ "at least one value"

      assert {:ok, %{filter: filter, definition_hash: nil}} =
               CloudQuote.parse(params(%{"service" => "instance"}))

      assert filter == %{}
    end

    test "a signer or script hash alone is refused, as the projection API refuses it" do
      assert {:error, [message]} =
               CloudQuote.parse(params(%{"filter" => %{"aip_signers" => @addr}}))

      assert message =~ "aren't indexed"
      assert message =~ "protocols"
    end

    test "bounds the values and checks the from block and namespace" do
      many = Enum.map_join(1..21, ",", &"v#{&1}")

      assert {:error, [message]} = CloudQuote.parse(params(%{"filter" => %{"protocols" => many}}))
      assert message =~ "at most 20"

      assert {:error, [message]} =
               CloudQuote.parse(
                 params(%{"filter" => %{"protocols" => "MAP"}, "from_height" => "-3"})
               )

      assert message =~ "From block"

      assert {:error, [message]} =
               CloudQuote.parse(params(%{"source" => "bitcom_commands", "namespace" => "nope"}))

      assert message =~ "Namespace"
    end

    test "a command projection has an empty filter and keeps the namespace" do
      assert {:ok, spec} =
               CloudQuote.parse(
                 params(%{
                   "source" => "bitcom_commands",
                   "namespace" => @ns,
                   "filter" => %{"protocols" => "MAP"}
                 })
               )

      assert spec.filter == %{}
      assert spec.namespace == @ns
      assert spec.definition_hash == Projection.definition_hash(%{}, "bitcom_commands")
    end
  end

  describe "estimate/3" do
    test "counts matching txs only within from_height..complete_through" do
      for h <- [5, 10, 20], do: transaction_fixture(%{block_height: h, protocols: ["MAP"]})
      transaction_fixture(%{block_height: 10, protocols: ["B"]})

      {:ok, spec} =
        CloudQuote.parse(params(%{"filter" => %{"protocols" => "MAP"}, "from_height" => "6"}))

      assert {:ok, %{count: 1, capped: false, from: 6, through: 15, unit: "transactions"}} =
               CloudQuote.estimate(spec, 15)
    end

    test "stops at the cap and says so" do
      for h <- 1..3, do: transaction_fixture(%{block_height: h, protocols: ["MAP"]})
      {:ok, spec} = CloudQuote.parse(params(%{"filter" => %{"protocols" => "MAP"}}))

      assert {:ok, %{count: 2, capped: true, cap: 2} = estimate} =
               CloudQuote.estimate(spec, 10, cap: 2)

      assert CloudQuote.estimate_line(estimate) =~ "more than 2 transactions in blocks 0 to 10"
    end

    test "counts commands in the log, narrowed by namespace" do
      for {ns, h} <- [{@ns, 3}, {@ns, 30}, {"1Other", 4}] do
        Repo.insert!(%Command{
          txid: unique_transaction_txid(),
          output_index: 0,
          command: "echo",
          namespace: ns,
          block_height: h
        })
      end

      {:ok, all} = CloudQuote.parse(params(%{"source" => "bitcom_commands"}))
      assert {:ok, %{count: 2, unit: "commands"}} = CloudQuote.estimate(all, 10)

      {:ok, one} = CloudQuote.parse(params(%{"source" => "bitcom_commands", "namespace" => @ns}))
      assert {:ok, %{count: 1}} = CloudQuote.estimate(one, 10)
    end

    test "says why there is no count" do
      {:ok, spec} = CloudQuote.parse(params(%{"filter" => %{"protocols" => "MAP"}}))
      assert {:error, :not_held} = CloudQuote.estimate(spec, nil)
      assert {:error, :not_held} = CloudQuote.estimate(%{spec | from_height: 50}, 10)

      {:ok, whole} = CloudQuote.parse(params(%{"service" => "instance"}))
      assert {:error, :whole_index} = CloudQuote.estimate(whole, 10)
    end
  end

  test "the mailto names the service and carries the filter and the estimate" do
    {:ok, spec} = CloudQuote.parse(params(%{"filter" => %{"protocols" => "MAP"}}))

    estimate = %{
      count: 7,
      capped: false,
      cap: 10_000,
      from: 0,
      through: 1_234,
      unit: "transactions"
    }

    "mailto:enterprise@bitblocks.app?" <> query =
      CloudQuote.mailto("enterprise@bitblocks.app", "projection", spec, estimate)

    %{"subject" => subject, "body" => body} = URI.decode_query(query)
    assert subject == "Cloud services quote: Managed projection"
    assert body =~ ~s"Filter (as the projection API takes it): {\"protocols\":[\"MAP\"]}"
    assert body =~ "Definition hash: #{spec.definition_hash}"
    assert body =~ "Estimate: 7 transactions in blocks 0 to 1,234 (complete through 1,234)"
  end
end
