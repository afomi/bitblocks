defmodule Bitblocks.AnnotationsTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.FirstSpendFixtures

  alias Bitblocks.Annotations

  describe "placing an annotation on the chain" do
    setup do
      insert_first_spend()
      # Genesis, so dates have a lower bound.
      Bitblocks.ChainFixtures.block_fixture(height: 0, time: 1_231_006_505)
      :ok
    end

    test "a height is where it draws" do
      {:ok, a} = Annotations.create(%{kind: "halving", title: "First halving", height: 210_000})
      assert {a.resolved_height, a.resolved_by} == {210_000, "height"}
    end

    test "a stored txid wins over the height given" do
      {:ok, a} =
        Annotations.create(%{
          kind: "milestone",
          title: "First spend",
          txid: first_spend(),
          height: 1
        })

      assert {a.resolved_height, a.resolved_by} == {170, "txid"}
    end

    test "a txid we don't hold yet falls back to the height, else waits" do
      unknown = String.duplicate("ab", 32)

      {:ok, with_height} =
        Annotations.create(%{kind: "mint", title: "A", txid: unknown, height: 5})

      assert with_height.resolved_height == 5

      {:ok, waiting} = Annotations.create(%{kind: "mint", title: "B", txid: unknown})
      assert waiting.resolved_height == nil
    end

    test "a date draws at the first block mined at or after it" do
      # Block 169, the one before, so there's no gap below 170.
      Bitblocks.ChainFixtures.block_fixture(height: 169, time: 1_231_700_000)

      {:ok, a} =
        Annotations.create(%{
          kind: "world",
          title: "Day of the first spend",
          occurred_at: "2009-01-12T00:00:00Z"
        })

      assert {a.resolved_height, a.resolved_by} == {170, "time"}
    end

    test "a date just past a gap in our headers waits instead of landing late" do
      # Blocks 0, 9 and 170 are stored; 2009-01-10 falls in the gap after 9.
      {:ok, a} =
        Annotations.create(%{
          kind: "world",
          title: "In the gap",
          occurred_at: "2009-01-10T00:00:00Z"
        })

      assert a.resolved_height == nil
    end

    test "a date before the genesis block stays off the chain, and says why" do
      {:ok, a} =
        Annotations.create(%{
          kind: "world",
          title: "Whitepaper",
          occurred_at: "2008-10-31T00:00:00Z"
        })

      assert {a.resolved_height, a.resolved_by} == {nil, "before_genesis"}
    end

    test "resolve_all places what has since arrived" do
      unknown = String.duplicate("cd", 32)
      {:ok, a} = Annotations.create(%{kind: "mint", title: "Later", txid: unknown})
      assert Annotations.resolve_all() == 0

      Repo.update_all(
        from(t in Bitblocks.Chain.Transaction, where: t.txid == ^first_spend()),
        set: [txid: unknown]
      )

      assert Annotations.resolve_all() == 1
      assert Annotations.get(a.id).resolved_height == 170
    end

    test "list_between/2 reads by drawn height, in chain order" do
      for {title, h} <- [{"c", 300}, {"a", 10}, {"b", 170}],
          do: {:ok, _} = Annotations.create(%{kind: "note", title: title, height: h})

      assert Annotations.list_between(0, 200) |> Enum.map(& &1.title) == ["a", "b"]
    end
  end

  describe "validation" do
    test "needs an anchor" do
      assert {:error, cs} = Annotations.create(%{kind: "note", title: "Floating"})
      assert %{height: ["set a height, a txid or a date"]} = errors_on(cs)
    end

    test "checks the kind, the txid and the source URL" do
      assert {:error, cs} =
               Annotations.create(%{
                 kind: "rumour",
                 title: "x",
                 txid: "nothex",
                 source_url: "javascript:alert(1)"
               })

      errors = errors_on(cs)
      assert errors.kind != []
      assert errors.txid == ["must be 64 hex characters"]
      assert errors.source_url == ["must start with http:// or https://"]
    end

    test "lowercases and trims a txid" do
      {:ok, a} =
        Annotations.create(%{
          kind: "note",
          title: "x",
          txid: " " <> String.upcase(String.duplicate("ab", 32))
        })

      assert a.txid == String.duplicate("ab", 32)
    end
  end

  describe "seed/0" do
    test "every curated event is valid, and seeding twice adds nothing" do
      {added, 0} = Annotations.seed()
      assert added > 10
      assert Annotations.seed() == {0, added}
    end

    test "the first spend is seeded with its real txid" do
      Annotations.seed()
      first = Enum.find(Annotations.list(), &(&1.txid == first_spend()))
      assert first.height == 170
    end
  end

  test "changes broadcast so open views redraw" do
    Phoenix.PubSub.subscribe(Bitblocks.PubSub, Annotations.topic())
    {:ok, a} = Annotations.create(%{kind: "note", title: "x", height: 1})
    assert_receive :annotations_changed
    {:ok, _} = Annotations.delete(a)
    assert_receive :annotations_changed
  end
end
