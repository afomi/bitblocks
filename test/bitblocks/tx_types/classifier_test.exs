defmodule Bitblocks.TxTypes.ClassifierTest do
  # afomi/bitblocks#49 phase 2: every output gets a type id from types.json
  # (unmatched is custom), and every tx a type made from its outputs. The
  # shared vectors in output_types_v1.json are the contract: each type in
  # types.json lists the vectors it covers under `vectors`, and every vector
  # must classify as the one type that claims it.
  use ExUnit.Case, async: true

  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Classifier

  @vectors "priv/data/tx_types/output_types_v1.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("vectors")

  defp script(hex), do: BSV.Script.from_binary!(hex, encoding: :hex)

  defp vector(name), do: Enum.find(@vectors, &(&1["name"] == name))

  defp out(%{"script_hex" => hex, "satoshis" => sats}),
    do: %BSV.TxOut{satoshis: sats, script: script(hex)}

  defp out(chunks, sats), do: %BSV.TxOut{satoshis: sats, script: %BSV.Script{chunks: chunks}}

  defp input(chunks) do
    %BSV.TxIn{
      outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0},
      script: %BSV.Script{chunks: chunks}
    }
  end

  @sig :binary.copy(<<0x30>>, 71)
  @pubkey <<0x02>> <> :binary.copy(<<0x11>>, 32)
  @p_node <<0x03>> <> :binary.copy(<<0x22>>, 32)
  @parent_txid :binary.copy(<<0x44>>, 32)

  describe "the shared vectors (output_types_v1.json)" do
    test "every vector is claimed by exactly one type in types.json" do
      for v <- @vectors do
        owners = for type <- TxTypes.all(), v["name"] in Map.get(type, :vectors, []), do: type.id

        assert [_one] = owners,
               "vector #{v["name"]} is claimed by #{inspect(owners)}, not by exactly one type"
      end

      names = Enum.map(@vectors, & &1["name"])

      for type <- TxTypes.all(), name <- Map.get(type, :vectors, []) do
        assert name in names, "#{type.id} claims unknown vector #{name}"
      end
    end

    for v <- @vectors do
      @vector v
      test "vector #{v["name"]} classifies as the type that claims it" do
        expected =
          Enum.find_value(TxTypes.all(), fn type ->
            if @vector["name"] in Map.get(type, :vectors, []), do: type.id
          end)

        assert Classifier.output_type(script(@vector["script_hex"]), @vector["satoshis"]) ==
                 expected,
               "#{@vector["name"]} (#{@vector["description"]})"
      end
    end
  end

  describe "output_type/2" do
    test "every result is a type id from types.json" do
      ids = TxTypes.ids()

      for v <- @vectors do
        assert Classifier.output_type(script(v["script_hex"]), v["satoshis"]) in ids
      end
    end

    test "an output no type matches is custom" do
      contract = %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}
      assert Classifier.output_type(contract, 5_000_000_000) == "custom"
      assert Classifier.output_type(%BSV.Script{chunks: []}, 0) == "custom"
    end

    test "OP_TRUE and OP_1 are the same byte, so the same type" do
      assert Classifier.output_type(%BSV.Script{chunks: [:OP_TRUE]}, 1000) == "anyone-can-spend"
      assert Classifier.output_type(%BSV.Script{chunks: [:OP_1]}, 1000) == "anyone-can-spend"
    end

    test "a 1-sat P2PKH is a 1sat output; any other value is P2PKH" do
      p2pkh = script(vector("p2pkh")["script_hex"])
      assert Classifier.output_type(p2pkh, 1) == "1sat-output"
      assert Classifier.output_type(p2pkh, 2) == "p2pkh"
      assert Classifier.output_type(p2pkh, 0) == "p2pkh"
    end

    test "multisig of any m and n is multisig" do
      one_of_two = %BSV.Script{chunks: [:OP_1, @pubkey, @pubkey, :OP_2, :OP_CHECKMULTISIG]}
      assert Classifier.output_type(one_of_two, 1000) == "multisig"
    end

    test "data outputs take the type of their first protocol, bare or OP_FALSE-prefixed" do
      assert Classifier.output_type(
               %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "run", <<5>>, "app", "{}"]},
               0
             ) ==
               "run"

      assert Classifier.output_type(%BSV.Script{chunks: [:OP_RETURN, "run", <<5>>]}, 0) == "run"

      assert Classifier.output_type(%BSV.Script{chunks: [:OP_FALSE, :OP_RETURN]}, 0) ==
               "op-return"
    end
  end

  describe "classify/1, a whole tx" do
    test "gives each output its type, in output order, and the tx the set in types.json order" do
      tx = %BSV.Tx{
        inputs: [input([@sig, @pubkey])],
        outputs: [
          out(vector("b_then_map")),
          out(vector("p2pkh")),
          out(vector("inscription_text")),
          out(vector("p2pkh"))
        ]
      }

      assert %{outputs: ["b", "p2pkh", "1sat-inscription", "p2pkh"], types: types} =
               Classifier.classify(tx)

      # b_then_map's data output carries MAP after the pipe: the tx is MAP too.
      assert types == ["p2pkh", "1sat-inscription", "b", "map"]
    end

    test "SIGMA after a pipe types the tx, not the output" do
      tx = %BSV.Tx{inputs: [input([@sig, @pubkey])], outputs: [out(vector("map_then_sigma"))]}
      assert %{outputs: ["map"], types: ["map", "sigma"]} = Classifier.classify(tx)
    end

    test "a tx with an unmatched output includes custom" do
      tx = %BSV.Tx{
        inputs: [input([@sig, @pubkey])],
        outputs: [out([:OP_ADD, :OP_EQUAL], 1000), out(vector("p2pkh"))]
      }

      assert %{outputs: ["custom", "p2pkh"], types: ["p2pkh", "custom"]} = Classifier.classify(tx)
    end

    test "the genesis coinbase is P2PK, not custom" do
      raw =
        "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

      assert {:ok, %{outputs: ["p2pk"], types: ["p2pk"]}} = Classifier.classify_raw(raw)
    end

    test "a compressed key is P2PK too; a push of any other size is custom" do
      compressed = out([<<2, 0::256>>, :OP_CHECKSIG], 1000)
      odd_size = out([:binary.copy(<<2>>, 20), :OP_CHECKSIG], 1000)
      tx = %BSV.Tx{inputs: [input([@sig])], outputs: [compressed, odd_size]}

      assert %{outputs: ["p2pk", "custom"]} = Classifier.classify(tx)
    end

    test "the script-hash shape is P2SH, and only with a 20-byte hash" do
      p2sh = out([:OP_HASH160, :binary.copy(<<7>>, 20), :OP_EQUAL], 1000)
      long = out([:OP_HASH160, :binary.copy(<<7>>, 32), :OP_EQUAL], 1000)
      tx = %BSV.Tx{inputs: [input([@sig])], outputs: [p2sh, long]}

      assert %{outputs: ["p2sh", "custom"]} = Classifier.classify(tx)
    end

    test "a Metanet root needs no parent signature" do
      meta = out([:OP_FALSE, :OP_RETURN, "meta", @p_node, <<>>], 0)
      tx = %BSV.Tx{inputs: [input([@sig])], outputs: [meta]}

      assert %{outputs: ["metanet"], types: ["metanet"]} = Classifier.classify(tx)
    end

    test "a Metanet child is a node only when an input is signed with a key" do
      meta = out([:OP_FALSE, :OP_RETURN, "meta", @p_node, @parent_txid, "name"], 0)

      signed = %BSV.Tx{inputs: [input([@sig, @pubkey])], outputs: [meta]}
      assert %{outputs: ["metanet"], types: ["metanet"]} = Classifier.classify(signed)

      # No input carries a public key, so no parent can have signed it.
      unsigned = %BSV.Tx{inputs: [input([@sig])], outputs: [meta]}
      assert %{outputs: ["op-return"], types: ["op-return"]} = Classifier.classify(unsigned)
    end

    test "classify_raw/1 decodes hex first, and says when it can't" do
      tx = %BSV.Tx{inputs: [input([@sig, @pubkey])], outputs: [out(vector("p2pkh"))]}
      hex = BSV.Tx.to_binary(tx, encoding: :hex)

      assert {:ok, %{types: ["p2pkh"]}} = Classifier.classify_raw(hex)
      assert {:error, _} = Classifier.classify_raw("zz")
      assert {:error, _} = Classifier.classify_raw(nil)
    end
  end

  test "version/0 is a positive integer" do
    assert is_integer(Classifier.version()) and Classifier.version() > 0
  end
end
