defmodule Bitblocks.Interop.VectorsTest do
  @moduledoc """
  Holds the published vectors to the code: every vector must produce its stated
  outcome through `Beef.Reader` and `BeefVerifier`, so the file can't drift.
  """
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.Chain.{BeefVerifier, Block, Headers}
  alias Bitblocks.Interop.Vectors
  alias Bitblocks.Repo

  @fixtures Path.expand("../../support/fixtures/brc", __DIR__)
  @doc_map Jason.decode!(Vectors.body())
  @vectors @doc_map["vectors"]
  @headers Map.new(@doc_map["headers"], &{&1["height"], &1})

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
  defp stringify(nil), do: nil
  defp stringify(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # As `Chain.Headers` gives a header we'd rely on, for `evaluate/3`.
  defp held(vector) do
    Map.new(vector["headers_held"], fn height ->
      header = Map.fetch!(@headers, height)

      {height,
       %{
         hash: header["hash"] || "synthetic",
         merkleroot: header["merkleroot"],
         num_tx: header["tx_count"],
         verified: true,
         canonical: true
       }}
    end)
  end

  defp tip(vector), do: Enum.max(vector["headers_held"], fn -> 1 end)

  defp assert_answer(answer, vector) do
    expected = vector["expected"]
    id = vector["id"]

    assert stringify(answer.status) == expected["outcome"], id
    assert stringify(answer.reason) == expected["reason"], id
    assert answer.format == expected["format"], id
    assert answer.subject_txid == expected["subject_txid"], id
    assert answer.in_block == expected["in_block"], id
    assert answer.block_height == expected["block_height"], id
    assert length(answer.transactions) == length(expected["transactions"]), id

    for {got, want} <- Enum.zip(answer.transactions, expected["transactions"]) do
      assert got.txid == want["txid"], id
      assert stringify(got.status) == want["status"], id
      assert stringify(got.reason) == want["reason"], id
      assert Map.get(got, :block_height) == want["block_height"], id
    end
  end

  # A real row, from the 80 bytes the file publishes, so the file's own header
  # is what passes `Chain.Headers`' hash and proof-of-work check.
  defp insert_header(%{"raw_header" => raw_hex} = header) do
    <<version::little-32, prev::binary-size(32), root::binary-size(32), time::little-32,
      bits::little-32, nonce::little-32>> = unhex(raw_hex)

    display = fn hash -> hash |> reverse() |> Base.encode16(case: :lower) end

    Repo.insert!(%Block{
      height: header["height"],
      hash: header["hash"],
      prevblockhash: display.(prev),
      merkleroot: display.(root),
      version: version,
      time: time,
      bits: bits |> Integer.to_string(16) |> String.downcase(),
      nonce: nonce,
      num_tx: header["tx_count"],
      sync_state: "header_only",
      tx: []
    })
  end

  describe "every vector does what it says" do
    for vector <- Enum.filter(@vectors, &(&1["kind"] == "beef")) do
      @vector vector

      test "#{vector["id"]}" do
        vector = @vector
        bytes = unhex(vector["hex"])

        case vector["expected"] do
          %{"outcome" => "refused", "reason" => reason} ->
            assert {:error, got} = Reader.parse(bytes)
            assert Atom.to_string(got) == reason
            assert {:error, ^got} = BeefVerifier.verify(bytes)

          _ ->
            {:ok, beef} = Reader.parse(bytes)
            assert_answer(BeefVerifier.evaluate(beef, held(vector), tip(vector)), vector)
        end
      end
    end

    for vector <- Enum.filter(@vectors, &(&1["kind"] == "bump")) do
      @vector vector

      test "#{vector["id"]}" do
        vector = @vector
        bytes = unhex(vector["hex"])

        case vector["expected"] do
          %{"outcome" => "refused", "reason" => reason} ->
            assert {:error, got} = Reader.parse_bump(bytes)
            assert Atom.to_string(got) == reason

          %{"outcome" => "root"} = expected ->
            assert {:ok, bump, ""} = Reader.parse_bump(bytes)
            assert bump.height == expected["block_height"]

            for %{"txid" => txid, "offset" => offset} <- expected["leaves"] do
              root = expected["merkleroot"]
              assert {:ok, ^root, ^offset} = Reader.root(bump, txid)
            end

            [height] = vector["headers_held"]
            assert Map.fetch!(@headers, height)["merkleroot"] == expected["merkleroot"]
        end
      end
    end
  end

  describe "against real headers, through the whole verifier" do
    test "every vector that rests on real headers gives the same answer from the database" do
      real = Enum.filter(@doc_map["headers"], &(&1["synthetic"] == false))
      Enum.each(real, &insert_header/1)

      synthetic =
        @doc_map["headers"] |> Enum.filter(& &1["synthetic"]) |> Enum.map(& &1["height"])

      vectors =
        for %{"kind" => "beef", "expected" => %{"outcome" => outcome}} = vector <- @vectors,
            outcome != "refused",
            not Enum.any?(vector["headers_held"], &(&1 in synthetic)) do
          vector
        end

      # A vector that holds no header must not find one in the rows above.
      for vector <- Enum.filter(vectors, &(&1["headers_held"] != [])) do
        assert {:ok, answer} = BeefVerifier.verify(unhex(vector["hex"]))
        assert_answer(answer, vector)
      end

      assert Enum.any?(vectors, &(&1["expected"]["outcome"] == "proven"))
      assert Enum.any?(vectors, &(&1["expected"]["outcome"] == "anchored"))
      assert Enum.any?(vectors, &(&1["expected"]["outcome"] == "failed"))
    end

    test "a vector that holds no header reads unknown with none stored" do
      vector = Enum.find(@vectors, &(&1["id"] == "brc62-example-no-header"))

      assert {:ok, answer} = BeefVerifier.verify(unhex(vector["hex"]))
      assert_answer(answer, vector)
    end

    test "each real header in the file passes its hash and proof of work" do
      for %{"synthetic" => false, "height" => height} = header <- @doc_map["headers"] do
        insert_header(header)

        assert %{verified: true, canonical: true, header: raw, merkleroot: root} =
                 Headers.at(height)

        assert raw == header["raw_header"]
        assert root == header["merkleroot"]
      end
    end
  end

  describe "what the file claims about itself" do
    test "the script builds exactly what's published" do
      {doc, _binding} = Code.eval_file("scripts/interop_vectors_v1.exs")

      assert doc |> Jason.encode!() |> Jason.decode!() == @doc_map
    end

    test "says what it doesn't cover, in the verifier's own terms" do
      {:ok, beef} = Reader.parse(unhex(hd(@vectors)["hex"]))
      answer = BeefVerifier.evaluate(beef, %{}, 1)

      assert @doc_map["not_checked"] == answer.not_checked
      assert @doc_map["claim"] =~ "inclusion in a block"
      assert @doc_map["version"] == Vectors.summary().version
    end

    test "says what it has been tried against, and names nobody as passing" do
      assert @doc_map["tried_against"] =~ "@bsv/sdk 2.4.0"
      assert @doc_map["tried_against"] =~ "no live wallet"
      assert @doc_map["tried_against"] =~ "Nothing in this file says"

      lower = String.downcase(Vectors.body())
      refute lower =~ "qart"
      refute lower =~ "passing"
      refute lower =~ "certified"
    end

    test "every vector has a known source, and every source a licence note and a url" do
      sources = Map.new(@doc_map["sources"], &{&1["id"], &1})

      for vector <- @vectors do
        assert vector["sources"] != [], vector["id"]
        assert Enum.all?(vector["sources"], &Map.has_key?(sources, &1)), vector["id"]
        assert is_boolean(vector["valid"]), vector["id"]
        assert vector["basis"] in ~w(BRC-62 BRC-74 BRC-95 BRC-96 hardening), vector["id"]
      end

      used = @vectors |> Enum.flat_map(& &1["sources"]) |> MapSet.new()

      for {id, source} <- sources do
        assert id in used, "#{id} is listed and unused"
        assert source["licence"] != "", id
        assert String.starts_with?(source["url"], "https://"), id
      end
    end

    test "ids are unique, and the file has valid and invalid vectors of each kind" do
      ids = Enum.map(@vectors, & &1["id"])

      assert ids == Enum.uniq(ids)

      for kind <- ~w(beef bump), valid <- [true, false] do
        assert Enum.any?(@vectors, &(&1["kind"] == kind and &1["valid"] == valid))
      end

      for format <- ~w(beef_v1 beef_v2 atomic_beef_v1 atomic_beef_v2) do
        assert Enum.any?(@vectors, &(&1["expected"]["format"] == format)), format
      end

      for outcome <- ~w(proven anchored unknown failed refused root) do
        assert Enum.any?(@vectors, &(&1["expected"]["outcome"] == outcome)), outcome
      end
    end

    test "the spec examples and the SDK's bytes are copied, not rewritten" do
      by_id = Map.new(@vectors, &{&1["id"], &1["hex"]})
      read = fn name -> @fixtures |> Path.join(name) |> File.read!() |> String.trim() end
      json = fn name -> name |> read.() |> Jason.decode!() end

      assert by_id["brc62-example"] == read.("brc62_beef.hex")
      assert by_id["brc74-example"] == read.("brc74_bump.hex")
      assert by_id["brc62-atomic-sdk"] == json.("beef_sdk_v1.json")["brc62_atomic"]
      assert by_id["brc62-v2-txid-only-sdk"] == json.("beef_sdk_v1.json")["brc62_v2_txid_only"]
      assert by_id["two-input-v1-sdk"] == json.("vault_beef_v1.json")["unsignedBeef"]
      assert by_id["two-input-v2-sdk"] == json.("beef_sdk_v1.json")["v2"]
      assert by_id["two-input-atomic-sdk"] == json.("beef_sdk_v1.json")["atomic_v1"]
      assert by_id["mainnet-bump"] == json.("woc_mainnet_v1.json")["bump"]
    end

    test "a made-up root says so, and offers no header bytes" do
      synthetic = Enum.filter(@doc_map["headers"], & &1["synthetic"])

      assert synthetic != []

      for header <- synthetic do
        assert header["raw_header"] == nil
        assert header["hash"] == nil
        assert header["note"] != ""
      end
    end
  end
end
