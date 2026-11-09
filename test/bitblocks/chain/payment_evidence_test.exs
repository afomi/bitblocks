defmodule Bitblocks.Chain.PaymentEvidenceTest do
  # #64: BRC-237 statements, distance only, against the spec's own test
  # vectors (test/fixtures/brc237/vectors.json, extracted from BRC-237 with
  # every material checked against the length and SHA-256 the spec gives).
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.PaymentEvidence

  @vectors "test/fixtures/brc237/vectors.json" |> File.read!() |> Jason.decode!()
  @made_at @vectors["made_at"]
  @tip @vectors["tip_height"]

  defp headers(extra \\ %{}) do
    @vectors["headers"]
    |> Map.new(fn {h, hex} -> {String.to_integer(h), Base.decode16!(hex, case: :lower)} end)
    |> Map.merge(Map.new(extra, fn {h, hex} -> {h, Base.decode16!(hex, case: :lower)} end))
  end

  defp source(headers \\ headers(), tip \\ @tip), do: %{headers: headers, tip: tip}

  defp material(%{"kind" => "beef", "hex" => hex}), do: {:beef, Base.decode16!(hex, case: :lower)}

  defp material(%{"kind" => "records"} = m) do
    {:records,
     %{
       transactions: Enum.map(m["transactions"], &Base.decode16!(&1, case: :lower)),
       paths: Map.new(m["electrum"], fn {txid, branch} -> {txid, {:electrum, branch}} end),
       payment: m["payment"]
     }}
  end

  defp statement(id), do: Enum.find(@vectors["statements"], &(&1["id"] == id))
  defp refusal(id), do: Enum.find(@vectors["refusals"], &(&1["id"] == id))
  defp beef(id), do: material(statement(id)["material"])

  # The S1 and M25 inputs: what the maker observed.
  @observed [
    event: "handed-to-broadcaster",
    conflicts: %{
      "at" => 1_793_318_340,
      "checked" => true,
      "found" => false,
      "kind" => "own-node",
      "scope" => "unconfirmed"
    }
  ]

  defp source_for("S10"), do: source(Map.take(headers(), [950_001]), 950_001)
  defp source_for("S11"), do: source(headers(%{950_000 => @vectors["header_950000"]}))
  defp source_for(_id), do: source()

  defp opts_for("S1"), do: [made_at: @made_at] ++ @observed
  defp opts_for(_id), do: [made_at: @made_at]

  # What a maker that runs no check of section 2.3 says in place of a
  # validating maker's lists: nothing validated, so no fee rate, and
  # validation "all" only when U is empty (the payment is an anchor).
  defp distance_only(expected) do
    %{
      expected
      | "validated" => [],
        "lowestFeeRate" => nil,
        "validation" => if(expected["unconfirmed"] == [], do: "all", else: "none")
    }
  end

  describe "the spec's statements" do
    for %{"id" => id, "title" => title} <- @vectors["statements"] do
      @id id
      test "#{title}" do
        vector = statement(@id)

        assert {:ok, bytes} =
                 PaymentEvidence.make(
                   material(vector["material"]),
                   source_for(@id),
                   opts_for(@id)
                 )

        expected = vector["statement"] |> Jason.decode!() |> distance_only()
        assert bytes == PaymentEvidence.canonical(expected)

        # A vector whose maker validated nothing is the distance-only maker's
        # own, byte for byte.
        if Jason.decode!(vector["statement"]) == expected,
          do: assert(bytes == vector["statement"])
      end
    end

    test "the distance-only vectors match byte for byte" do
      for id <- ~w(S3 S4 S7 S8 S9 S10 S12 S16) do
        assert {:ok, bytes} = PaymentEvidence.make(beef(id), source_for(id), opts_for(id))
        assert bytes == statement(id)["statement"], id
      end
    end
  end

  describe "the spec's refusals a distance-only maker makes" do
    setup do
      <<prefix::binary-size(36), body::binary>> = s1 = elem(beef("S1"), 1)
      %{s1: s1, prefix: prefix, body: body}
    end

    test "M1, M2, M3, M16: material that doesn't frame is MALFORMED", ctx do
      truncated = binary_part(ctx.s1, 0, byte_size(ctx.s1) - 1)
      <<_version::binary-size(4), rest::binary>> = ctx.body
      legacy = ctx.prefix <> <<0xEF, 0xBE, 0x00, 0x01>> <> rest
      m3 = Base.decode16!(@vectors["m3_input"], case: :lower)

      for bytes <- [truncated, ctx.s1 <> <<0>>, m3, legacy] do
        assert PaymentEvidence.make({:beef, bytes}, source(), made_at: @made_at) ==
                 {:error, "MALFORMED"}
      end
    end

    test "M4: a path whose root is not the header's is ANCHOR_MISMATCH", ctx do
      headers = headers(%{950_001 => @vectors["m4_header_950001"]})

      assert PaymentEvidence.make({:beef, ctx.s1}, source(headers), made_at: @made_at) ==
               {:error, "ANCHOR_MISMATCH"}
    end

    for id <- ~w(M8 M11 M14 M15 M17 M18 M19 M20 M23 M24) do
      @id id
      test "#{id}: #{Enum.find(@vectors["refusals"], &(&1["id"] == id))["title"]}" do
        vector = refusal(@id)

        assert PaymentEvidence.make(material(vector["material"]), source(), made_at: @made_at) ==
                 {:error, vector["code"]}
      end
    end

    test "M9, M10, M13, M21, M25: past each bound is OVER_BOUND", ctx do
      s2 = beef("S2")
      m21 = material(refusal("M21")["material"])

      # M25's bound is one byte under S1's statement. A distance-only S1 is
      # shorter than the spec's (no fee rate, nothing validated), so it is
      # one byte under ours.
      {:ok, s1} =
        PaymentEvidence.make({:beef, ctx.s1}, source(), [made_at: @made_at] ++ @observed)

      for {material, opts} <- [
            {s2, max_transactions: 3},
            {s2, max_distance: 2},
            {{:beef, ctx.s1}, max_material_bytes: 432},
            {m21, max_material_bytes: 768},
            {{:beef, ctx.s1}, [max_statement_bytes: byte_size(s1) - 1] ++ @observed}
          ] do
        assert PaymentEvidence.make(material, source(), [made_at: @made_at] ++ opts) ==
                 {:error, "OVER_BOUND"}
      end

      # One byte more, and each is made.
      assert {:ok, _} =
               PaymentEvidence.make(m21, source(), made_at: @made_at, max_material_bytes: 769)

      assert {:ok, ^s1} =
               PaymentEvidence.make(
                 {:beef, ctx.s1},
                 source(),
                 [made_at: @made_at, max_statement_bytes: byte_size(s1)] ++ @observed
               )
    end

    test "M5, M6, M7, M12, M22 are refusals of checks a distance-only maker never runs" do
      # A maker that ran check 1, 2 or 3 refuses these; one that ran none makes
      # a distance-only statement (S9 is M6's material, said so in the spec).
      extra = %{
        "M12" => headers(%{950_000 => @vectors["header_950000"]}),
        "M22" => headers(%{949_999 => @vectors["header_949999"]})
      }

      for id <- ~w(M5 M6 M7 M12 M22) do
        hs = source(Map.get(extra, id, headers()))

        assert {:ok, statement} =
                 PaymentEvidence.make(material(refusal(id)["material"]), hs, made_at: @made_at)

        assert %{"validation" => "none", "validated" => []} = Jason.decode!(statement)
      end
    end
  end

  describe "Electrum-form branches (section 6)" do
    test "E5's branch converts to the spec's BRC-74 bytes" do
      e5 = Base.decode16!(@vectors["transactions"]["E5"], case: :lower)

      branch = %{
        "block_height" => 950_006,
        "merkle" => [
          "ed1c8314bd18dfb4fd9ef30e067899b2719d6df46730470e8ae22e4c8fee67a3",
          "6b157ae9550c8fac7e5aab7c7121162e30ae5cb397a4bd97a661df741d2fcd44",
          "9655485f14b20de881eefc0d22692ea5c3d9b724db6afe9206fbeb30eb5885b8"
        ],
        "pos" => 4
      }

      assert {:ok, bytes} = PaymentEvidence.electrum_to_brc74(branch, e5)
      assert Base.encode16(bytes, case: :lower) == @vectors["paths"]["E5"]

      # pos 12 leaves a bit over after three siblings; 65 siblings is past BRC-74.
      assert PaymentEvidence.electrum_to_brc74(%{branch | "pos" => 12}, e5) == :error

      long = %{branch | "merkle" => List.duplicate(hd(branch["merkle"]), 65), "pos" => 0}
      assert PaymentEvidence.electrum_to_brc74(long, e5) == :error
    end

    test "every anchor's branch converts to its BRC-74 path" do
      for {name, branch} <- @vectors["electrum"] do
        raw = Base.decode16!(@vectors["transactions"][name], case: :lower)
        assert {:ok, bytes} = PaymentEvidence.electrum_to_brc74(branch, raw), name
        assert Base.encode16(bytes, case: :lower) == @vectors["paths"][name], name
      end
    end
  end
end
