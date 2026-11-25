defmodule Bitblocks.Elections.DraftTest do
  @moduledoc """
  The `/elections/new` form is checked with the count's own rules, and every
  refusal the count makes of an election or roll has plain words beside a
  field.
  """
  use ExUnit.Case, async: true

  import Bitblocks.ElectionFixtures, only: [key: 0]

  alias Bitblocks.Elections.{Count, Draft}

  @tip 1_000

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "PBA Board 2026",
        "number_elected" => "2",
        "votes_allowed" => "",
        "candidates" => "Alice\nBob\nCarol",
        "members" => key().address,
        "opens_at_height" => "1007",
        "closes_at_height" => "2014"
      },
      overrides
    )
  end

  defp errors(overrides, tip \\ @tip) do
    {:error, errors} = Draft.parse(params(overrides), tip)
    errors
  end

  test "a good form is a draft, votes_allowed defaulting to the seats" do
    assert {:ok, draft} = Draft.parse(params(), @tip)
    assert draft.election["votes_allowed"] == 2
    refute draft.votes_allowed_given
  end

  test "every count refusal of an election or roll has plain words and a field" do
    for {kind, detail} = refusal <- Count.refusals(),
        kind in [:invalid_election, :invalid_roll] do
      message = Draft.message(refusal, @tip)
      refute message == detail, "no plain words for #{inspect(refusal)}"
      assert is_binary(Draft.field(refusal)) or Draft.field(refusal) == :form
    end
  end

  test "the parts the form sets map to its fields" do
    for {_kind, detail} = refusal <- Count.refusals(),
        String.starts_with?(detail, [
          "number_elected",
          "votes_allowed",
          "candidate",
          "opens",
          "closes"
        ]) do
      assert Draft.field(refusal) in Draft.fields(), "#{detail} has no field"
    end
  end

  test "several broken parts are named at once, each beside its field" do
    errors =
      errors(%{
        "number_elected" => "0",
        "candidates" => "Bad_Id: Someone\nalice: Alice",
        "opens_at_height" => "2000",
        "closes_at_height" => "1500"
      })

    assert errors["number_elected"] == ["Seats must be 1 or more."]

    assert errors["candidates"] == [
             "Candidate ids use only lowercase letters a to z, digits 0 to 9 and hyphens."
           ]

    assert errors["closes_at_height"] == ["Voting must close at or after the block it opens at."]
  end

  test "voting must open after the block the records can first confirm in" do
    assert errors(%{"opens_at_height" => "1001"})["opens_at_height"] == [
             "Voting must open after block 1001, so the roll and the election can confirm before the first ballot counts."
           ]

    assert {:ok, _} = Draft.parse(params(%{"opens_at_height" => "1002"}), @tip)
  end

  test "duplicate candidate ids are refused, as the count refuses them" do
    assert errors(%{"candidates" => "Alice\nalice: Alice again"})["candidates"] == [
             "Two candidates have the same id; give each its own."
           ]
  end

  test "text that isn't a number, a blank name, no candidates, a bad address" do
    errors =
      errors(%{
        "name" => " ",
        "number_elected" => "three",
        "candidates" => "",
        "members" => "1notanaddress not-an-address"
      })

    assert errors["name"] == ["Give the election a name."]
    assert errors["number_elected"] == ["Enter seats as a whole number."]
    assert errors["candidates"] == ["Add at least one candidate."]

    assert errors["members"] == [
             "These aren't P2PKH addresses (they start with 1): 1notanaddress, not-an-address."
           ]
  end

  test "a name the id can't be made from asks for one" do
    assert errors(%{"candidates" => "李明"})["candidates"] == [
             "Give “李明” an id, written as id: 李明."
           ]
  end

  test "about a week from the tip: six blocks to confirm, then 1,008 blocks of voting" do
    assert Draft.week_window(1_000) == %{opens: 1_007, closes: 2_014}
    assert 2_014 - 1_007 + 1 == Draft.week()
    assert Draft.week_window(nil) == nil
  end

  test "with_roll takes an outpoint or a bare txid, and refuses anything else" do
    {:ok, draft} = Draft.parse(params(), @tip)
    txid = String.duplicate("ab", 32)

    assert {:ok, %{"roll" => roll}} = Draft.with_roll(draft, txid)
    assert roll == txid <> ".0"
    assert {:ok, %{"roll" => ^roll}} = Draft.with_roll(draft, " #{String.upcase(txid)}.0 ")
    assert {:ok, %{"roll" => r1}} = Draft.with_roll(draft, txid <> ".1")
    assert r1 == txid <> ".1"

    assert Draft.with_roll(draft, "nope") ==
             {:error, "Enter the roll's outpoint as <txid>.<vout>."}
  end
end
