defmodule BitblocksWeb.FreshnessTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  import BitblocksWeb.Freshness

  alias BitblocksWeb.Freshness

  # The line as a reader sees it, whitespace collapsed.
  defp line(assigns) do
    assigns
    |> freshness()
    |> rendered_to_string()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp base(attrs) do
    Map.merge(
      %{
        __changed__: nil,
        id: nil,
        label: "Current to",
        through: nil,
        tip: nil,
        time: nil,
        now: nil,
        link: false,
        class: "",
        inner_block: []
      },
      attrs
    )
  end

  describe "wording" do
    test "behind the tip, it names the block and how far behind" do
      assert line(base(%{through: 422_382, tip: 976_935})) ==
               "Current to block 422,382 · 554,553 blocks behind the chain"

      assert line(base(%{through: 9, tip: 10})) == "Current to block 9 · 1 block behind the chain"
    end

    test "at the tip, it says so and still names the block" do
      assert line(base(%{through: 975_001, tip: 975_001})) ==
               "Current to block 975,001 · the chain tip"
    end

    test "with headers we don't know, it says the tip isn't known rather than guess" do
      assert line(base(%{through: 600_000})) == "Current to block 600,000 · chain tip not known"
    end

    test "with no block to name, it says it isn't known yet" do
      assert line(base(%{tip: 10})) == "Current to: not known yet"
      assert line(base(%{through: -1, tip: 10})) == "Current to: not known yet"
    end

    test "a scoped label keeps the same shape" do
      assert line(base(%{label: "Files indexed through", through: 600_000, tip: 975_001})) ==
               "Files indexed through block 600,000 · 375,001 blocks behind the chain"
    end

    test "with the block's time, it says how long ago it was mined" do
      now = 1_800_000_000

      assert line(base(%{through: 0, tip: 5, time: now - 3 * 3_600, now: now})) ==
               "Current to block 0, mined 3 hours ago · 5 blocks behind the chain"
    end

    test "text/3 reads the same as the component" do
      assert Freshness.text(422_382, 976_935) ==
               "Current to block 422,382 · 554,553 blocks behind the chain"

      assert Freshness.text("Counts through", 1, 1) == "Counts through block 1 · the chain tip"
      assert Freshness.text(nil, 1) == "Current to: not known yet"
    end
  end

  describe "markup" do
    test "is a labelled note, with its state as data and the block in mono" do
      html = rendered_to_string(freshness(base(%{id: "f", through: 1, tip: 3, link: true})))

      assert html =~ ~s(role="note")
      assert html =~ ~s(aria-label="How current this is")
      assert html =~ ~s(data-freshness="behind")
      assert html =~ ~s(href="/blocks/1")
      assert html =~ "font-mono tabular-nums"
    end

    test "renders words before the line from its slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.freshness
          through={1}
          tip={1}
        >
          <strong>In development.</strong>
        </.freshness>
        """)

      assert html =~ "<strong>In development.</strong>"
      assert html =~ ~s(data-freshness="at_tip")
    end
  end

  test "snapshot/0 reads the shared sync snapshot, nil until it knows" do
    assert %{through: through, tip: tip} = Freshness.snapshot()
    assert is_nil(through) or is_integer(through)
    assert is_nil(tip) or is_integer(tip)
  end
end
