defmodule Bitblocks.TxTypes.ProposalTest do
  # #51 step 5: propose_type drafts a type from a real custom output, as a
  # change to types.json and chain_vectors.json for a person to review.
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.{Script, TxTypes}
  alias Bitblocks.TxTypes.Proposal

  @contract %BSV.Script{chunks: [<<7::160>>, :OP_DROP, :OP_ADD, :OP_EQUAL]}

  setup do
    {txid, _hex} =
      built =
      tx([funding_outpoint()], [p2pkh(address(), 900), %BSV.TxOut{satoshis: 5, script: @contract}])

    publish(built)
    %{txid: txid, hash: Script.template_hash(@contract)}
  end

  test "drafts a type matched by the output's template hash, with its vector", ctx do
    assert {:ok, draft} =
             Proposal.draft("push-add-equal", ctx.txid, ctx.hash,
               title: "Push, add, equal",
               related: ["p2pkh"]
             )

    assert draft.vout == 1
    type = Jason.decode!(Jason.encode!(draft.type))

    assert type["id"] == "push-add-equal"
    assert type["title"] == "Push, add, equal"
    assert type["group"] == "other"
    assert type["vectors"] == ["chain_push_add_equal"]

    assert %{
             "kind" => "template",
             "vector" => "chain_push_add_equal",
             "template_hashes" => hashes
           } =
             type["examples"]

    assert hd(hashes) == ctx.hash
    assert Enum.sort(hashes) == TxTypes.template_hash_variants(@contract)

    # Prose nobody gave reads TODO, which the types test refuses.
    assert type["summary"] =~ Proposal.todo()
    assert type["spend"] =~ Proposal.todo()

    vector = Jason.decode!(Jason.encode!(draft.vector))
    assert vector["txid"] == ctx.txid
    assert vector["vout"] == 1
    assert vector["satoshis"] == 5
    script = BSV.Script.from_binary!(vector["script_hex"], encoding: :hex)
    assert Script.template_hash(script) == ctx.hash
  end

  test "writes the type just before custom and leaves the rest of types.json as it was", ctx do
    root = Path.join(System.tmp_dir!(), "proposal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "priv/data/tx_types"))

    for file <- ["priv/data/tx_types/types.json", Proposal.vectors_file()],
        do: File.cp!(file, Path.join(root, file))

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, draft} = Proposal.draft("push-add-equal", ctx.txid, ctx.hash)
    assert {:ok, [types_path, vectors_path]} = Proposal.write(draft, root)

    before = File.read!("priv/data/tx_types/types.json")
    written = File.read!(types_path)

    ids = written |> Jason.decode!() |> Map.fetch!("types") |> Enum.map(& &1["id"])
    assert Enum.take(ids, -2) == ["push-add-equal", "custom"]
    assert ids -- ["push-add-equal"] == TxTypes.ids()

    # Only lines were added: every original line is still there, in order.
    assert List.myers_difference(String.split(before, "\n"), String.split(written, "\n"))
           |> Keyword.delete(:eq)
           |> Keyword.keys()
           |> Enum.uniq() == [:ins]

    vectors_before =
      Proposal.vectors_file() |> File.read!() |> Jason.decode!() |> Map.fetch!("vectors")

    vectors = vectors_path |> File.read!() |> Jason.decode!() |> Map.fetch!("vectors")

    # The new vector goes last; the ones already there stay as they were.
    assert Enum.drop(vectors, -1) == vectors_before
    assert %{"name" => "chain_push_add_equal", "txid" => txid} = List.last(vectors)
    assert txid == ctx.txid
  end

  test "refuses an id taken, an output already typed, and a hash the tx doesn't hold", ctx do
    assert {:error, {:type_exists, "p2pkh"}} = Proposal.draft("p2pkh", ctx.txid, ctx.hash)

    assert {:error, {:not_a_slug, "Not A Slug"}} =
             Proposal.draft("Not A Slug", ctx.txid, ctx.hash)

    p2pkh_hash = hd(TxTypes.get("p2pkh").examples.template_hashes)

    assert {:error, {:already_typed, "p2pkh"}} =
             Proposal.draft("my-payment", ctx.txid, p2pkh_hash)

    assert {:error, :no_output_with_that_template_hash} =
             Proposal.draft("nothing", ctx.txid, String.duplicate("0", 64))

    assert {:error, {:unknown_group, "nope"}} =
             Proposal.draft("push-add-equal", ctx.txid, ctx.hash, group: "nope")

    assert {:error, :tx_not_found} =
             Proposal.draft("push-add-equal", String.duplicate("e", 64), ctx.hash)
  end
end
