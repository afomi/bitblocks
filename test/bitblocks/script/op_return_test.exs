defmodule Bitblocks.Script.OpReturnTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Script.OpReturn

  defp script(chunks), do: %BSV.Script{chunks: chunks}

  describe "op_return_script?/1 and raw_chunks/1" do
    test "bare and OP_FALSE-prefixed OP_RETURN" do
      assert OpReturn.op_return_script?(script([:OP_RETURN, "a"]))
      assert OpReturn.op_return_script?(script([:OP_FALSE, :OP_RETURN, "a"]))
      refute OpReturn.op_return_script?(script([:OP_DUP, "a"]))

      assert OpReturn.raw_chunks(script([:OP_RETURN, "a", "b"])) == ["a", "b"]
      assert OpReturn.raw_chunks(script([:OP_FALSE, :OP_RETURN, "a"])) == ["a"]
      assert OpReturn.raw_chunks(script(["a"])) == []
    end
  end

  describe "parse_data/1" do
    test "structures push-data and opcode chunks" do
      parsed = OpReturn.parse_data(script([:OP_RETURN, "hello", :OP_1, <<0xFF, 0xFE>>]))

      assert [
               %{type: :push_data, utf8: "hello", hex: "68656c6c6f", length: 5},
               %{type: :opcode, name: "OP_1"},
               %{type: :push_data, utf8: nil, hex: "fffe", length: 2}
             ] = parsed
    end
  end

  describe "hex_data/1" do
    test "hex of push-data chunks only" do
      assert OpReturn.hex_data(script([:OP_RETURN, "ab", :OP_1])) == ["6162"]
    end
  end

  describe "utf8_chunks/1 and pipe_segments/1" do
    test "utf8_chunks keeps only decodable push data" do
      parsed = OpReturn.parse_data(script([:OP_RETURN, "a", <<0xFF>>, "b"]))
      assert OpReturn.utf8_chunks(parsed) == ["a", "b"]
    end

    test "pipe_segments splits the piped-protocol convention" do
      chunks = ["B_ADDR", "content", "|", "MAP_ADDR", "SET", "app", "x"]

      assert OpReturn.pipe_segments(chunks) == [
               ["B_ADDR", "content"],
               ["MAP_ADDR", "SET", "app", "x"]
             ]
    end
  end
end
