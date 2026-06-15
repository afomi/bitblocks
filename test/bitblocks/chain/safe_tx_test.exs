defmodule Bitblocks.Chain.SafeTxTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.SafeTx

  # Bitcoin's genesis coinbase tx — a known-good decode.
  @genesis_coinbase "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  describe "from_hex/1 — happy path" do
    test "decodes a valid transaction" do
      assert {:ok, %BSV.Tx{}} = SafeTx.from_hex(@genesis_coinbase)
    end

    test "accepts upper-case hex" do
      assert {:ok, %BSV.Tx{}} = SafeTx.from_hex(String.upcase(@genesis_coinbase))
    end
  end

  describe "from_hex/1 — bounds (CWE-770)" do
    test "rejects empty input" do
      assert {:error, :empty} = SafeTx.from_hex("")
    end

    test "rejects oversized input before decoding" do
      Application.put_env(:bitblocks, SafeTx, max_hex_bytes: 100)
      on_exit(fn -> Application.delete_env(:bitblocks, SafeTx) end)

      assert {:error, :too_large} = SafeTx.from_hex(String.duplicate("a", 101))
    end

    test "rejects non-binary input" do
      assert {:error, :not_binary} = SafeTx.from_hex(nil)
      assert {:error, :not_binary} = SafeTx.from_hex(123)
      assert {:error, :not_binary} = SafeTx.from_hex(%{})
    end
  end

  describe "from_hex/1 — known crashers are now total (threat T5)" do
    # These inputs make BSV.Tx.from_binary/2 raise CaseClauseError directly.
    # SafeTx must convert each into a typed error instead.
    for {name, hex} <- [
          {"truncated header", "0100000001"},
          {"all-ff garbage", "ffffffffffffffff"},
          {"oversized varint count", "01000000fdffff00"},
          {"odd-length hex", "abc"},
          {"non-hex chars", "zzzz"},
          {"lone byte", "00"}
        ] do
      test "returns a typed error, never raises: #{name}" do
        assert {:error, reason} = SafeTx.from_hex(unquote(hex))
        assert is_atom(reason)
      end
    end
  end

  describe "fuzz battery — the decoder is total on hostile input" do
    # A deterministic, seeded fuzzer: ~30k adversarial inputs across several
    # categories. A fixed seed keeps it reproducible in CI. The single
    # invariant: from_hex/1 ALWAYS returns {:ok, _} or {:error, _} and NEVER
    # raises, throws, or exits — no matter the input.
    @iterations 30_000

    test "no input causes a raise/throw/exit" do
      :rand.seed(:exsss, {1, 2, 3})

      failures =
        Enum.reduce(1..@iterations, [], fn i, acc ->
          input = fuzz_input(i)

          result =
            try do
              SafeTx.from_hex(input)
            rescue
              e -> {:raised, e.__struct__}
            catch
              kind, value -> {:caught, kind, value}
            end

          case result do
            {:ok, _} -> acc
            {:error, reason} when is_atom(reason) -> acc
            other -> [{i, summarize(input), other} | acc]
          end
        end)

      assert failures == [],
             "SafeTx.from_hex was not total for #{length(failures)} input(s): " <>
               inspect(Enum.take(failures, 5))
    end

    # Generate one adversarial input. Rotates through categories so the corpus
    # spans: random hex, near-valid txs (genesis with bytes flipped/truncated),
    # boundary varint encodings, repeated/structured bytes, and non-binaries.
    defp fuzz_input(i) do
      case rem(i, 8) do
        0 -> random_hex(:rand.uniform(64))
        1 -> random_hex(:rand.uniform(2_000))
        2 -> mutate(genesis())
        3 -> truncate(genesis())
        4 -> varint_edge()
        5 -> String.duplicate(Enum.random(["00", "ff", "fd", "ab"]), :rand.uniform(500))
        6 -> non_hex_noise(:rand.uniform(100))
        7 -> Enum.random([nil, 0, :atom, %{}, [], {1, 2}, 3.14])
      end
    end

    defp genesis,
      do:
        "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

    defp random_hex(byte_len) do
      :crypto.strong_rand_bytes(byte_len) |> Base.encode16(case: :lower)
    end

    # Flip a random hex nibble in the genesis tx → "almost valid" inputs.
    defp mutate(hex) do
      pos = :rand.uniform(String.length(hex)) - 1
      replacement = Enum.random(String.graphemes("0123456789abcdef"))
      String.slice(hex, 0, pos) <> replacement <> String.slice(hex, (pos + 1)..-1//1)
    end

    defp truncate(hex) do
      keep = :rand.uniform(String.length(hex))
      String.slice(hex, 0, keep)
    end

    # Varint length-prefix edge cases (the source of several library crashes).
    defp varint_edge do
      prefix = Enum.random(["fc", "fd", "fe", "ff"])
      "01000000" <> prefix <> random_hex(:rand.uniform(8))
    end

    defp non_hex_noise(len) do
      1..len
      |> Enum.map(fn _ -> Enum.random(String.graphemes("ghijklmnopqrstuvwxyz!@#$%^&* /:")) end)
      |> Enum.join()
    end

    defp summarize(input) when is_binary(input),
      do: "binary(#{byte_size(input)}): #{String.slice(input, 0, 32)}"

    defp summarize(input), do: inspect(input)
  end
end
