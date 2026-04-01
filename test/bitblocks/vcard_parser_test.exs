defmodule Bitblocks.VcardParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.VcardParser

  @vcard_v4 """
  BEGIN:VCARD
  VERSION:4.0
  FN:Ryan Wold
  ORG:Bitblocks
  EMAIL:ryan@example.com
  TEL;TYPE=work:+1-555-0100
  TEL;TYPE=home:+1-555-0200
  URL:https://ryanwold.net
  END:VCARD
  """

  @vcard_v3 """
  BEGIN:VCARD
  VERSION:3.0
  FN:Satoshi Nakamoto
  EMAIL:satoshi@vistomail.com
  END:VCARD
  """

  describe "is_vcard?/1" do
    test "detects valid vCard" do
      assert VcardParser.is_vcard?(@vcard_v4)
      assert VcardParser.is_vcard?(@vcard_v3)
    end

    test "rejects non-vCard text" do
      refute VcardParser.is_vcard?("just some text")
      refute VcardParser.is_vcard?("")
      refute VcardParser.is_vcard?(nil)
      refute VcardParser.is_vcard?("BEGIN:VCARD\nbut no end")
    end
  end

  describe "parse/1" do
    test "parses v4 vCard with all fields" do
      {:ok, vcard} = VcardParser.parse(@vcard_v4)

      assert vcard.version == "4.0"
      assert VcardParser.get_field(vcard, "FN") == "Ryan Wold"
      assert VcardParser.get_field(vcard, "ORG") == "Bitblocks"
      assert VcardParser.get_field(vcard, "EMAIL") == "ryan@example.com"
      assert VcardParser.get_field(vcard, "URL") == "https://ryanwold.net"
    end

    test "parses v3 vCard" do
      {:ok, vcard} = VcardParser.parse(@vcard_v3)

      assert vcard.version == "3.0"
      assert VcardParser.get_field(vcard, "FN") == "Satoshi Nakamoto"
    end

    test "extracts multiple values for repeated fields" do
      {:ok, vcard} = VcardParser.parse(@vcard_v4)

      tels = VcardParser.get_fields(vcard, "TEL")
      assert length(tels) == 2
      assert "+1-555-0100" in tels
      assert "+1-555-0200" in tels
    end

    test "parses field parameters" do
      {:ok, vcard} = VcardParser.parse(@vcard_v4)

      tel_fields = Enum.filter(vcard.fields, fn f -> f.name == "TEL" end)
      work_tel = Enum.find(tel_fields, fn f -> f.params["TYPE"] == "work" end)
      assert work_tel.value == "+1-555-0100"
    end

    test "returns error for non-vCard input" do
      assert {:error, _} = VcardParser.parse("not a vcard")
      assert {:error, _} = VcardParser.parse(nil)
    end

    test "preserves raw text" do
      {:ok, vcard} = VcardParser.parse(@vcard_v4)
      assert vcard.raw == @vcard_v4
    end
  end

  describe "from_op_return_chunks/1" do
    test "extracts vCard from OP_RETURN data chunks" do
      chunks = [
        %{type: :push_data, utf8: @vcard_v4, hex: "...", length: byte_size(@vcard_v4)}
      ]

      {:ok, vcard} = VcardParser.from_op_return_chunks(chunks)
      assert vcard.version == "4.0"
      assert VcardParser.get_field(vcard, "FN") == "Ryan Wold"
    end

    test "assembles vCard split across multiple chunks" do
      chunks = [
        %{type: :push_data, utf8: "BEGIN:VCARD\nVERSION:4.0\n", hex: "...", length: 10},
        %{type: :push_data, utf8: "FN:Split Person\n", hex: "...", length: 10},
        %{type: :push_data, utf8: "END:VCARD", hex: "...", length: 10}
      ]

      {:ok, vcard} = VcardParser.from_op_return_chunks(chunks)
      assert VcardParser.get_field(vcard, "FN") == "Split Person"
    end

    test "returns error when no vCard found" do
      chunks = [
        %{type: :push_data, utf8: "just regular data", hex: "...", length: 10}
      ]

      assert {:error, _} = VcardParser.from_op_return_chunks(chunks)
    end

    test "skips non-push-data chunks" do
      chunks = [
        %{type: :opcode, opcode: 106, name: "OP_RETURN"},
        %{type: :push_data, utf8: @vcard_v3, hex: "...", length: 10}
      ]

      {:ok, vcard} = VcardParser.from_op_return_chunks(chunks)
      assert VcardParser.get_field(vcard, "FN") == "Satoshi Nakamoto"
    end
  end

  describe "get_field/2" do
    test "returns nil for missing field" do
      {:ok, vcard} = VcardParser.parse(@vcard_v3)
      assert VcardParser.get_field(vcard, "TEL") == nil
    end
  end
end
