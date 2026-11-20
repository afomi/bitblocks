defmodule Bitblocks.Elections.CountTest do
  @moduledoc """
  Holds the published vectors (`priv/data/interop/election_count_v0.json`) to
  `Bitblocks.Elections.Count`: every vector must produce its stated outcome, so
  the file a recount reuses can't drift from the code.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Elections.{Count, CountVectors}

  @doc_map Jason.decode!(CountVectors.body())
  @vectors @doc_map["vectors"]

  # The result as JSON reads it: atoms become strings.
  defp as_json(result), do: result |> Jason.encode!() |> Jason.decode!()

  defp run(%{"input" => input}) do
    Count.count(
      input["election"],
      input["roll"],
      input["ballots"],
      close_block_hash: input["close_block_hash"]
    )
  end

  for vector <- @vectors do
    @vector vector
    test "vector #{vector["id"]}" do
      expected = @vector["expected"]

      case {run(@vector), expected} do
        {{:error, error}, %{"error" => code, "error_detail" => detail}} ->
          assert Atom.to_string(elem(error, 0)) == code
          assert List.last(Tuple.to_list(error)) == detail

        {{:ok, result}, %{"error" => code}} ->
          flunk("expected error #{code}, got #{inspect(result)}")

        {{:ok, result}, _} ->
          json = as_json(result)
          assert json["election"] == @vector["input"]["election"]["election"]
          assert Map.delete(json, "election") == expected

        {{:error, error}, _} ->
          flunk("unexpected error #{inspect(error)}")
      end
    end
  end

  describe "the published file" do
    test "names every rule the code applies, and no other" do
      assert Map.keys(@doc_map["rules"]) |> Enum.sort() ==
               Count.rules() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "rule_order is the order the code applies the rules" do
      assert @doc_map["rule_order"] == Enum.map(Count.rules(), &Atom.to_string/1)
    end

    test "every refusal has a vector, and every error vector is a refusal" do
      refusals = for {kind, detail} <- Count.refusals(), do: {Atom.to_string(kind), detail}

      in_vectors =
        for %{"expected" => %{"error" => kind, "error_detail" => detail}} <- @vectors,
            do: {kind, detail}

      assert Enum.sort(Enum.uniq(in_vectors)) == Enum.sort(refusals)
    end

    test "served as v0, a draft, with an SPDX licence and its URL" do
      assert @doc_map["status"] == "draft"
      assert @doc_map["version"] =~ ~r/^0\./
      assert @doc_map["url"] == "https://bitblocks.app/interop/elections/count/v0.json"
      assert @doc_map["licence"] == "MIT"
      assert @doc_map["licence_url"] =~ ~r{^https://}
    end

    test "every election id, roll and ballot's election is an outpoint" do
      outpoint = ~r/\A[0-9a-f]{64}\.(0|[1-9][0-9]*)\z/

      for %{"input" => %{"election" => %{} = e} = input, "expected" => expected} <- @vectors,
          not Map.has_key?(expected, "error") do
        assert e["election"] =~ outpoint
        assert e["roll"] =~ outpoint
        for b <- input["ballots"], do: assert(b["election"] =~ outpoint)
      end
    end

    test "every rule is exercised by at least one vector" do
      used =
        for v <- @vectors,
            b <- v["expected"]["ballots"] || [],
            b["rule"],
            into: MapSet.new(),
            do: b["rule"]

      assert MapSet.new(Map.keys(@doc_map["rules"])) == used
    end

    test "vector ids are unique" do
      ids = Enum.map(@vectors, & &1["id"])
      assert ids == Enum.uniq(ids)
    end

    test "the lot in tie-by-lot is the sha256 it states" do
      vector = Enum.find(@vectors, &(&1["id"] == "tie-by-lot"))
      hash = vector["input"]["close_block_hash"]

      for id <- ~w(ben cy di) do
        assert vector["description"] =~ "#{id} #{Count.lot(hash, id)}"
      end
    end
  end

  describe "properties beyond the vectors" do
    setup do
      %{"input" => input} = Enum.find(@vectors, &(&1["id"] == "all-counted"))
      %{input: input}
    end

    test "input order never changes the result", %{input: input} do
      {:ok, a} = Count.count(input["election"], input["roll"], input["ballots"])
      {:ok, b} = Count.count(input["election"], input["roll"], Enum.reverse(input["ballots"]))
      assert a == b
    end

    test "an uppercase close block hash draws the same lot" do
      assert Count.lot("AB" <> String.duplicate("0", 62), "ada") ==
               Count.lot("ab" <> String.duplicate("0", 62), "ada")
    end

    test "no ballots: zero votes, no winners", %{input: input} do
      assert {:ok, %{counted: 0, not_counted: 0, winners: [], undecided: nil, tally: tally}} =
               Count.count(input["election"], input["roll"], [])

      assert Enum.all?(tally, &(&1.votes == 0))
    end

    test "votes_allowed defaults to number_elected", %{input: input} do
      e = Map.delete(input["election"], "votes_allowed")
      ballot = hd(input["ballots"])
      three = Map.put(ballot, "choices", ["ada", "ben", "cy"])

      assert {:ok, %{ballots: [%{rule: :too_many_choices}]}} =
               Count.count(e, input["roll"], [three])

      assert {:ok, %{ballots: [%{counted: true}]}} =
               Count.count(Map.put(e, "votes_allowed", 3), input["roll"], [three])
    end

    test "an election or roll without its own height is counted", %{input: input} do
      e = Map.delete(input["election"], "height")
      roll = Map.delete(input["roll"], "height")
      assert {:ok, _} = Count.count(e, roll, input["ballots"])
    end

    test "malformed elections, rolls and ballots are refused", %{input: input} do
      e = input["election"]
      roll = input["roll"]

      assert {:error, {:invalid_election, _}} =
               Count.count(Map.put(e, "number_elected", 0), roll, [])

      assert {:error, {:invalid_election, "candidate ids must be unique"}} =
               Count.count(
                 Map.put(e, "candidates", [%{"id" => "a"}, %{"id" => "a"}]),
                 roll,
                 []
               )

      for bad <- ["", "a b", "a:b", "A", "é"] do
        assert {:error,
                {:invalid_election, "candidate ids must be one or more of a-z, 0-9 and -"}} =
                 Count.count(Map.put(e, "candidates", [%{"id" => bad}]), roll, [])
      end

      for bad <- ["e1.0", String.duplicate("e1", 32) <> ".01", String.duplicate("E1", 32) <> ".0"] do
        assert {:error, {:invalid_election, _}} =
                 Count.count(Map.put(e, "election", bad), roll, [])
      end

      assert {:error, {:invalid_roll, _}} = Count.count(e, %{"members" => [1]}, [])
      assert {:error, {:invalid_roll, _}} = Count.count(e, nil, [])
      assert {:error, {:invalid_ballot, nil, _}} = Count.count(e, roll, [%{}])

      assert {:error, {:invalid_ballot, "t", _}} =
               Count.count(e, roll, [%{"txid" => "t", "height" => 1001, "position" => nil}])

      assert {:error, {:invalid_ballot, "t", _}} =
               Count.count(e, roll, [%{"txid" => "t", "height" => -1, "position" => 0}])
    end
  end
end
