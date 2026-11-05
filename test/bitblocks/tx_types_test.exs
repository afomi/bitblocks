defmodule Bitblocks.TxTypesTest do
  use ExUnit.Case, async: true

  alias Bitblocks.TxTypes

  @vectors "priv/data/tx_types/output_types_v1.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("vectors")
           |> Map.new(&{&1["name"], &1})

  test "every type has the fields a page needs" do
    for type <- TxTypes.all() do
      assert type.id =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, "#{type.id} is not a slug"

      for key <- [:title, :short, :group, :summary, :spend],
          do: assert(is_binary(type[key]) and type[key] != "", "#{type.id} lacks #{key}")

      assert [_ | _] = type.description
      assert [_ | _] = type.history
      assert type.spec.url =~ ~r{\Ahttps://}
      assert is_binary(type.spec.label)
      assert [_ | _] = type.pattern.parts
      assert Enum.all?(type.pattern.parts, &(is_binary(&1.token) and is_binary(&1.label)))
      assert is_boolean(type.spendable)
      assert type.examples.kind in ~w(tokens collections template protocol none)
    end
  end

  test "ids are unique and every group and related id resolves" do
    ids = TxTypes.ids()
    assert ids == Enum.uniq(ids)

    group_ids = Enum.map(TxTypes.groups(), & &1.id)

    for type <- TxTypes.all() do
      assert type.group in group_ids, "#{type.id} has unknown group #{type.group}"

      for related <- type.related do
        assert TxTypes.get(related), "#{type.id} relates to unknown #{related}"
        refute related == type.id
      end
    end
  end

  test "ships the slugs other tools link to" do
    for id <- ~w(p2pkh 1sat-inscription ordlock bsv-20 bsv-21 op-return b map metanet custom) do
      assert TxTypes.get(id), "missing #{id}"
    end
  end

  test "a template source lists every hash its vector's shape can be stamped with" do
    for %{examples: %{kind: "template"} = examples} = type <- TxTypes.all() do
      vector = Map.fetch!(@vectors, examples.vector)
      script = BSV.Script.from_binary!(vector["script_hex"], encoding: :hex)
      variants = TxTypes.template_hash_variants(script)

      assert Enum.sort(examples.template_hashes) == variants,
             "#{type.id}: template hashes do not match vector #{examples.vector}"

      assert Bitblocks.Script.template_hash(script) in variants
    end
  end

  test "a template source lists the canonical hash first, the one new rows are stamped with" do
    for %{examples: %{kind: "template"} = examples} = type <- TxTypes.all() do
      script =
        @vectors
        |> Map.fetch!(examples.vector)
        |> Map.fetch!("script_hex")
        |> BSV.Script.from_binary!(encoding: :hex)

      assert hd(examples.template_hashes) == Bitblocks.Script.template_hash(script),
             "#{type.id}: the first template hash is not the canonical one"
    end
  end

  test "an aliased opcode gives a hash for each of its names" do
    op_true = %BSV.Script{chunks: [:OP_TRUE]}
    op_1 = %BSV.Script{chunks: [:OP_1]}

    assert TxTypes.template_hash_variants(op_true) == TxTypes.template_hash_variants(op_1)

    assert TxTypes.template_hash_variants(op_true) ==
             Enum.sort(for name <- ["OP_1", "OP_TRUE"], do: sha256(name))

    p2pkh = %BSV.Script{chunks: [:OP_DUP, :OP_HASH160, <<0::160>>, :OP_EQUALVERIFY, :OP_CHECKSIG]}
    assert [_one] = TxTypes.template_hash_variants(p2pkh)
  end

  test "P2PKH's template hash is the one both projects agree on" do
    assert TxTypes.get("p2pkh").examples.template_hashes ==
             ["09507a7ca50f690592bd1c63b0c826f82e835c4b68d967aea9c5e2c4e666b2d5"]
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  test "Metanet carries the paper, its concepts and the CC BY-SA attribution" do
    type = TxTypes.get("metanet")
    paper = "https://nchain.com/wp-content/uploads/2022/09/The-Metanet-Technical-Summary-v1.0.pdf"

    assert type.spec.url == paper
    assert type.attribution.source_url == paper
    assert type.attribution.license == "CC BY-SA 4.0"

    terms = Enum.map(type.concepts, & &1.term)

    for term <- ["Node", "Edge", "Root", "Versions", "MURL", "Search", "Insertion methods"],
        do: assert(term in terms, "missing concept #{term}")
  end

  test "get!/1 raises a 404 error for an unknown id" do
    error = assert_raise TxTypes.NotFoundError, fn -> TxTypes.get!("no-such-type") end
    assert Plug.Exception.status(error) == 404
  end

  test "token and collection standards map to their type pages" do
    assert TxTypes.id_for_standard("bsv-20") == "bsv-20"
    assert TxTypes.id_for_standard("bsv-21") == "bsv-21"
    assert TxTypes.id_for_standard("1Sat") == "1sat-inscription"
    assert TxTypes.id_for_standard("Run") == "run"
    assert TxTypes.id_for_standard("other") == nil
    assert TxTypes.id_for_standard(nil) == nil
  end
end
