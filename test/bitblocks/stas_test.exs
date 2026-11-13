defmodule Bitblocks.StasTest do
  # #78: STAS token outputs, read from real outputs on chain
  # (chain_vectors.json's chain_stas and test/support/data/stas_outputs.json,
  # each checked against its txid when it was taken).
  use ExUnit.Case, async: true

  alias Bitblocks.Stas
  alias Bitblocks.TxTypes.Classifier

  @outputs "test/support/data/stas_outputs.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("outputs")
           |> Map.new(&{&1["txid"], &1})

  @chain_stas "priv/data/tx_types/chain_vectors.json"
              |> File.read!()
              |> Jason.decode!()
              |> Map.fetch!("vectors")
              |> Enum.find(&(&1["name"] == "chain_stas"))

  @chain_stas20 "priv/data/tx_types/chain_vectors.json"
                |> File.read!()
                |> Jason.decode!()
                |> Map.fetch!("vectors")
                |> Enum.find(&(&1["name"] == "chain_stas20"))

  defp script(%{"script_hex" => hex}), do: BSV.Script.from_binary!(hex, encoding: :hex)
  defp output(txid), do: Map.fetch!(@outputs, txid)

  test "an issuance: the owner, the token id, the flags and the data" do
    # Output 0 of 0f9e2366…54a8, block 707,635. WhatsOnChain names this token
    # 1567a67c…58b9 (GET /v1/bsv/main/token/<id>/<symbol>).
    assert {:ok, token} = Stas.parse(script(@chain_stas))

    assert token.redemption_pkh == "1567a67c7efcbd12825e7cd0480fa3100e1d58b9"
    assert token.token_id == "12xBMnFKjatg1djQwFnCMyu1PN9uH4hUBJ"
    assert token.owner_pkh == "1567a67c7efcbd12825e7cd0480fa3100e1d58b9"
    assert token.owner == "12xBMnFKjatg1djQwFnCMyu1PN9uH4hUBJ"
    assert token.version == "STAS"
    assert token.flags == "01"
    assert token.splittable == false
    assert token.data == ["Token"]
  end

  test "a splittable token" do
    out = output("fac78ebc53e6b6bcf66367d0e93bcd7b66d2b28f99e0b555181fc5999f55b682")
    assert {:ok, token} = Stas.parse(script(out))

    assert token.redemption_pkh == "617b84206f91180229b5161a57910e17e3f4cf42"
    assert token.token_id == "19tSWfAa1S3sHf7jMiz5BdSKyKdL7NGBSg"
    assert token.flags == "00"
    assert token.splittable == true
    assert token.data == ["Token"]
  end

  test "an owner who isn't the issuer, and JSON data" do
    out = output("15f5f0ebfb2981c1ac739cddeeed059f09448a4287ef551a0309a4ae5cd8aef5")
    assert {:ok, token} = Stas.parse(script(out))

    assert token.owner_pkh == "1c0267d70bac012001048a187b42f27c6a64c978"
    assert token.redemption_pkh == "66b18f01e45e6178da5e080619b829824df5e728"
    assert [json] = token.data
    assert %{"author" => _} = Jason.decode!(json)
  end

  test "a STAS-20 output: its own contract, no flags byte, always splittable" do
    # Output 0 of 7b678504…c233, block 787,411: the STAS SDK's instantMint
    # example, issued with the STAS-20 template.
    out = output("7b678504f67fc87e93ddd6816800d73915cd43a09ad2a53d177cc539b3f8c233")
    assert out["script_hex"] == @chain_stas20["script_hex"]
    assert {:ok, token} = Stas.parse(script(out))

    # Issued to the issuer's own key, as the example does.
    assert token.version == "STAS-20"
    assert token.owner_pkh == "c2cebcc42b70706d28c9f5ac645b0a9babb3c05a"
    assert token.owner == token.token_id
    assert token.redemption_pkh == "c2cebcc42b70706d28c9f5ac645b0a9babb3c05a"
    assert token.flags == nil
    assert token.splittable == true
    assert token.data == ["TESTTOKEN001", "STAS TOKEN TESTING"]
  end

  test "every STAS output is typed stas, whatever data follows" do
    for out <- [
          @chain_stas,
          @chain_stas20,
          output("7b678504f67fc87e93ddd6816800d73915cd43a09ad2a53d177cc539b3f8c233"),
          output("55945951d953e13254e7213d3e75a143f2c9bf9dfdc273df8637981bf7f1e8a4"),
          output("fac78ebc53e6b6bcf66367d0e93bcd7b66d2b28f99e0b555181fc5999f55b682"),
          output("15f5f0ebfb2981c1ac739cddeeed059f09448a4287ef551a0309a4ae5cd8aef5")
        ] do
      assert Classifier.output_type(script(out), out["satoshis"]) == "stas", out["txid"]
    end
  end

  test "a STAS output with more data pushes is still STAS" do
    hex = @chain_stas["script_hex"] <> "03616263"
    script = BSV.Script.from_binary!(hex, encoding: :hex)

    assert {:ok, %{data: ["Token", "abc"]}} = Stas.parse(script)
    assert Classifier.output_type(script, 1) == "stas"
  end

  test "the issuer's contract output isn't a STAS output" do
    out = output("f428dd42ad0a42319c1d4131d2052600de899e145ea313e593b094b0c566e28d")
    assert Stas.parse(script(out)) == :error
    refute Classifier.output_type(script(out), out["satoshis"]) == "stas"
  end

  test "one changed byte in the contract isn't STAS" do
    for vector <- [@chain_stas, @chain_stas20] do
      <<head::binary-100, byte, rest::binary>> =
        Base.decode16!(vector["script_hex"], case: :lower)

      tampered = head <> <<Bitwise.bxor(byte, 1)>> <> rest

      assert Stas.parse(tampered) == :error
    end

    assert Stas.parse(<<0x76, 0xA9, 0x14>>) == :error
  end

  test "data_text/1 shows printable data as text, the rest as hex" do
    assert Stas.data_text("Token sn 2") == "Token sn 2"
    assert Stas.data_text(<<0, 255>>) == "00ff"
  end
end
