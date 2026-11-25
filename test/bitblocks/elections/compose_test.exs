defmodule Bitblocks.Elections.ComposeTest do
  @moduledoc """
  The composer and the parser agree: records built by `Compose` for
  `/elections/new`, signed here with a test key as a wallet would sign them,
  read back through `Records` as the same election and roll, and count.
  """
  use ExUnit.Case, async: true

  import Bitblocks.ElectionFixtures, only: [key: 0, output: 2, tx: 1, txid: 1]

  alias Bitblocks.Elections.{Compose, Count, Draft, Records}

  @tip 975_000

  setup do
    admin = key()
    members = for _ <- 1..4, do: key().address

    params = %{
      "name" => "PBA Board 2026",
      "number_elected" => "3",
      "votes_allowed" => "",
      "candidates" =>
        "ada: Ada Okafor\nbea: Bea Lindqvist\nChen Wei\ndara-o: Dara O'Neill\nEli Moreau",
      # Unsorted, one twice, apart by commas and lines.
      "members" =>
        Enum.join([Enum.at(members, 2), Enum.at(members, 0)], ",\n") <>
          "\n" <> Enum.join(Enum.drop(members, 1) ++ [Enum.at(members, 2)], " "),
      "opens_at_height" => "975,007",
      "closes_at_height" => "976014"
    }

    {:ok, draft} = Draft.parse(params, @tip)
    %{admin: admin, members: members, draft: draft}
  end

  # As a wallet signs: the unsigned script's pushes, with AIP appended over
  # the message Compose names.
  defp sign(record, signer) do
    {:ok, %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN | pushes]}} =
      BSV.Script.from_binary(record.script_hex, encoding: :hex)

    assert pushes == record.pushes

    assert Base.decode16!(record.message_hex, case: :lower) ==
             IO.iodata_to_binary([<<0x6A>>, pushes, "|"])

    output(pushes, signer)
  end

  test "the draft reads the form into the count's shapes", %{draft: draft, members: members} do
    assert draft.members == Enum.sort(members)
    assert draft.repeated_members == 2
    assert draft.election["number_elected"] == 3
    assert draft.election["votes_allowed"] == 3
    assert draft.election["opens_at_height"] == 975_007
    assert draft.election["closes_at_height"] == 976_014

    assert Enum.map(draft.election["candidates"], & &1["id"]) ==
             ["ada", "bea", "chen-wei", "dara-o", "eli-moreau"]

    assert Enum.at(draft.election["candidates"], 3)["name"] == "Dara O'Neill"
  end

  test "compose, sign with a test key, parse: the same roll and election, and they count", %{
    admin: admin,
    draft: draft
  } do
    roll = Compose.roll(draft.members)
    roll_tx = tx([sign(roll, admin)])
    roll_outpoint = "#{txid(roll_tx)}.0"

    assert {:ok, parsed_roll} = Records.parse_output(roll_tx, 0)
    assert parsed_roll.kind == :roll
    assert parsed_roll.signer == admin.address
    assert parsed_roll.fields["members"] == draft.members
    assert parsed_roll.fields["content"] == roll.content
    assert parsed_roll.fields["sha256"] == roll.sha256
    assert roll.sha256 == draft.election["roll_sha256"]

    # The txid the wallet returns, alone, means output 0.
    assert {:ok, election} = Draft.with_roll(draft, txid(roll_tx))
    assert election["roll"] == roll_outpoint

    record = Compose.election(election, election["roll"], election["roll_sha256"])
    election_tx = tx([sign(record, admin)])

    assert {:ok, parsed} = Records.parse_output(election_tx, 0)
    assert parsed.kind == :election
    assert parsed.signer == admin.address

    assert parsed.fields == %{
             "name" => "PBA Board 2026",
             "number_elected" => 3,
             "votes_allowed" => 3,
             "candidates" => draft.election["candidates"],
             "opens_at_height" => 975_007,
             "closes_at_height" => 976_014,
             "roll" => roll_outpoint,
             "roll_sha256" => roll.sha256
           }

    # And the count takes what the parser read, as the live page will.
    input =
      Map.merge(parsed.fields, %{"election" => "#{txid(election_tx)}.0", "height" => @tip + 1})

    assert {:ok, %{winners: [], counted: 0}} =
             Count.count(input, %{"members" => parsed_roll.fields["members"]}, [])
  end

  test "an unsigned record is no record: the AIP is the wallet's to add", %{draft: draft} do
    roll = Compose.roll(draft.members)
    {:ok, script} = BSV.Script.from_binary(roll.script_hex, encoding: :hex)
    bytes = tx([%BSV.TxOut{satoshis: 0, script: script}])

    assert Records.parse_output(bytes, 0) == {:error, :no_signature}
  end

  test "the createAction request carries the unsigned script as output 0, in order", %{
    draft: draft
  } do
    roll = Compose.roll(draft.members)
    request = Jason.decode!(roll.create_action_json)

    assert [%{"lockingScript" => script, "satoshis" => 0} = out] = request["outputs"]
    assert script == roll.script_hex
    assert String.length(out["outputDescription"]) in 5..50
    assert String.length(request["description"]) in 5..50
    assert request["options"] == %{"randomizeOutputs" => false}
    assert request["labels"] == ["election", "roll_v1"]
  end

  test "integers go on chain as decimal ASCII, lists as one JSON array", %{draft: draft} do
    pairs = Map.new(Compose.election_pairs(draft.election, nil, "ab"))

    assert pairs["number_elected"] == "3"
    assert pairs["opens_at_height"] == "975007"
    assert pairs["roll"] == nil

    assert pairs["candidates"] ==
             ~s([{"id":"ada","name":"Ada Okafor"},{"id":"bea","name":"Bea Lindqvist"},) <>
               ~s({"id":"chen-wei","name":"Chen Wei"},{"id":"dara-o","name":"Dara O'Neill"},) <>
               ~s({"id":"eli-moreau","name":"Eli Moreau"}])
  end
end
