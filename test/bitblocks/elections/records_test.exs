defmodule Bitblocks.Elections.RecordsTest do
  @moduledoc """
  Election records read from tx bytes (`docs/ELECTION_DOGFOOD.md`, "Records").
  Each record is signed here with a generated key, in the wallet's own
  script format, so `Bitblocks.Aip` checks it as it checks the chain.
  """
  use ExUnit.Case, async: false

  import Bitblocks.ElectionFixtures

  alias Bitblocks.Elections.{Count, Records}

  @election "#{String.duplicate("ab", 32)}.0"
  @roll "#{String.duplicate("cd", 32)}.1"
  @sha String.duplicate("e", 64)

  setup do
    %{admin: key(), member: key()}
  end

  defp parse(output), do: Records.parse_output(tx([output]), 0)

  describe "an election" do
    test "reads into the shape count/4 takes", %{admin: admin} do
      assert {:ok, record} = parse(output(election_fields({@roll, @sha}), admin))

      assert record.kind == :election
      assert record.signer == admin.address
      assert record.signature_error == nil

      assert record.fields == %{
               "name" => "PBA Board 2026",
               "number_elected" => 2,
               "votes_allowed" => 2,
               "candidates" => [
                 %{"id" => "alice", "name" => "Alice"},
                 %{"id" => "bob", "name" => "Bob"},
                 %{"id" => "carol", "name" => "Carol"}
               ],
               "opens_at_height" => 12,
               "closes_at_height" => 15,
               "roll" => @roll,
               "roll_sha256" => @sha
             }

      input = Map.merge(record.fields, %{"election" => @election})
      assert {:ok, %{tally: [_, _, _]}} = Count.count(input, %{"members" => []}, [])
    end

    test "votes_allowed is optional", %{admin: admin} do
      fields = election_fields({@roll, @sha}, %{"votes_allowed" => nil})
      assert {:ok, record} = parse(output(fields, admin))
      refute Map.has_key?(record.fields, "votes_allowed")
    end

    test "needs a signature that checks", %{admin: admin} do
      fields = election_fields({@roll, @sha})
      assert parse(output(fields, admin, unsigned: true)) == {:error, :no_signature}
      assert parse(output(fields, admin, bad_signature: true)) == {:error, :invalid_signature}
    end

    test "a signature over chosen fields that leaves one out counts for nothing", %{admin: admin} do
      fields = election_fields({@roll, @sha})
      # Field 1 is the MAP prefix; leave out the last value.
      some = Enum.map(1..(length(fields) - 1), &Integer.to_string/1)

      assert parse(output(fields, admin, indexes: some)) ==
               {:error, :signature_does_not_cover_fields}
    end

    test "a signature naming every field counts", %{admin: admin} do
      fields = election_fields({@roll, @sha})
      every = Enum.map(1..length(fields), &Integer.to_string/1)

      assert {:ok, %{signer: signer}} = parse(output(fields, admin, indexes: every))
      assert signer == admin.address
    end

    test "integers are decimal ASCII with no leading zeros", %{admin: admin} do
      for bad <- ["012", "1e3", "-1", " 12", ""] do
        fields = election_fields({@roll, @sha}, %{"opens_at_height" => bad})

        assert parse(output(fields, admin)) ==
                 {:error, {:bad_field, "opens_at_height", "decimal ASCII with no leading zeros"}}
      end
    end

    test "a list is one JSON array", %{admin: admin} do
      fields = election_fields({@roll, @sha}, %{"candidates" => "alice,bob"})

      assert parse(output(fields, admin)) ==
               {:error, {:bad_field, "candidates", "one JSON array"}}
    end

    test "names its roll by outpoint and hash", %{admin: admin} do
      fields = election_fields({"#{String.duplicate("cd", 32)}:1", @sha})
      assert {:error, {:bad_field, "roll", _}} = parse(output(fields, admin))

      fields = election_fields({@roll, String.upcase(@sha)})
      assert {:error, {:bad_field, "roll_sha256", _}} = parse(output(fields, admin))
    end

    test "a missing field is named", %{admin: admin} do
      fields = election_fields({@roll, @sha}, %{"name" => nil})
      assert parse(output(fields, admin)) == {:error, {:missing_field, "name"}}
    end

    test "a repeated key is refused, since MAP would keep only the last", %{admin: admin} do
      fields = election_fields({@roll, @sha}) ++ ["name", "Other"]
      assert parse(output(fields, admin)) == {:error, {:repeated_key, "name"}}
    end
  end

  describe "a roll" do
    test "is the B:// file, with its exact bytes and their sha256", %{
      admin: admin,
      member: member
    } do
      content = roll_file([member.address, admin.address])

      assert {:ok, record} = parse(output(roll_fields(content), admin))
      assert record.kind == :roll
      assert record.signer == admin.address
      assert record.fields["content"] == content
      assert record.fields["members"] == Enum.sort([member.address, admin.address])

      assert record.fields["sha256"] ==
               :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    end

    test "a signature over the MAP alone leaves the file unsigned", %{admin: admin} do
      fields = roll_fields(roll_file([admin.address]))
      # The MAP segment starts after the B segment's five pushes and its "|".
      map_only = Enum.map(7..length(fields), &Integer.to_string/1)

      assert parse(output(fields, admin, indexes: map_only)) ==
               {:error, :signature_does_not_cover_fields}
    end

    test "must be JSON with members", %{admin: admin} do
      assert {:error, {:bad_field, "members", _}} = parse(output(roll_fields("[1,2]"), admin))
    end
  end

  describe "a ballot" do
    test "reads election, choices and signer", %{member: member} do
      assert {:ok, record} = parse(output(ballot_fields(@election, ["alice", "bob"]), member))

      assert record.kind == :ballot
      assert record.signer == member.address
      assert record.fields == %{"election" => @election, "choices" => ["alice", "bob"]}
    end

    test "without a signature is still a ballot, so the count can list it", %{member: member} do
      assert {:ok, record} =
               parse(output(ballot_fields(@election, ["alice"]), member, unsigned: true))

      assert record.signer == nil
      assert record.signature_error == :no_signature

      assert {:ok, record} =
               parse(output(ballot_fields(@election, ["alice"]), member, bad_signature: true))

      assert record.signer == nil
      assert record.signature_error == :invalid_signature
    end

    test "choices that aren't a JSON list reach the count as they are", %{member: member} do
      assert {:ok, %{fields: %{"choices" => "alice"}}} =
               parse(output(ballot_fields(@election, "alice"), member))

      election = %{
        "election" => @election,
        "number_elected" => 1,
        "candidates" => [%{"id" => "alice"}],
        "opens_at_height" => 1,
        "closes_at_height" => 2,
        "roll" => @roll,
        "roll_sha256" => @sha
      }

      ballot = %{
        "txid" => "t",
        "election" => @election,
        "height" => 1,
        "position" => 1,
        "signer" => member.address,
        "choices" => "alice"
      }

      assert {:ok, %{ballots: [%{rule: :malformed_choices}]}} =
               Count.count(election, %{"members" => [member.address]}, [ballot])
    end

    test "must name an election outpoint", %{member: member} do
      assert {:error, {:bad_field, "election", _}} =
               parse(output(ballot_fields("not-an-outpoint", []), member))
    end
  end

  describe "a result" do
    test "reads its four fields", %{admin: admin} do
      fields =
        map_fields("result_v1", [
          {"election", @election},
          {"archive_sha256", @sha},
          {"closes_at_height", "15"},
          {"close_block_hash", String.duplicate("0", 64)}
        ])

      assert {:ok, %{kind: :result, fields: fields}} = parse(output(fields, admin))
      assert fields["closes_at_height"] == 15
    end
  end

  describe "not a record" do
    test "another app, an unknown type, no MAP, no output", %{admin: admin} do
      assert parse(output(map_fields("ballot_v1", [], app: "twetch"), admin)) ==
               {:error, :other_app}

      assert parse(output(map_fields("ballot_v2", []), admin)) ==
               {:error, {:unknown_type, "ballot_v2"}}

      assert parse(output(["hello"], admin)) == {:error, :no_map}
      assert Records.parse_output(tx([output(["hello"], admin)]), 3) == {:error, :no_output}
      assert Records.parse_output(<<1, 2, 3>>, 0) == {:error, :invalid_tx}
    end

    test "the app comes from config", %{member: member} do
      fields =
        map_fields("ballot_v1", [{"election", @election}, {"choices", "[]"}], app: "civic-vote")

      bytes = tx([output(fields, member)])
      assert Records.parse_output(bytes, 0) == {:error, :other_app}

      previous = Application.get_env(:bitblocks, :election_app)
      Application.put_env(:bitblocks, :election_app, "civic-vote")

      try do
        assert {:ok, %{kind: :ballot}} = Records.parse_output(bytes, 0)
      after
        Application.put_env(:bitblocks, :election_app, previous)
      end
    end
  end

  test "parse_tx/1 finds every record output, in order", %{admin: admin, member: member} do
    bytes =
      tx([
        output(["hello"], admin),
        output(roll_fields(roll_file([member.address])), admin),
        output(ballot_fields(@election, []), member)
      ])

    assert {:ok, [%{kind: :roll, vout: 1}, %{kind: :ballot, vout: 2}]} = Records.parse_tx(bytes)
  end
end
