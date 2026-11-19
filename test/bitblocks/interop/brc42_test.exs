defmodule Bitblocks.Interop.Brc42Test do
  @moduledoc """
  BRC-42 against its published vectors: the ten in BRC-42's own "Test
  Vectors" section (key-derivation/0042.md in bitcoin-sv/BRCs), which
  `@bsv/sdk` runs as `BRC42.private.vectors` and `BRC42.public.vectors`, and
  `@bsv/sdk`'s BRC-3 compliance vector (ProtoWallet.test.ts), a signature
  checked through a public child for anyone.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Interop.Brc42

  # BRC-42, "For Testing Private Key Derivation".
  @private [
    {"033f9160df035156f1c48e75eae99914fa1a1546bec19781e8eddb900200bff9d1",
     "6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede", "f3WCaUmnN9U=",
     "761656715bbfa172f8f9f58f5af95d9d0dfd69014cfdcacc9a245a10ff8893ef"},
    {"027775fa43959548497eb510541ac34b01d5ee9ea768de74244a4a25f7b60fae8d",
     "cab2500e206f31bc18a8af9d6f44f0b9a208c32d5cca2b22acfe9d1a213b2f36", "2Ska++APzEc=",
     "09f2b48bd75f4da6429ac70b5dce863d5ed2b350b6f2119af5626914bdb7c276"},
    {"0338d2e0d12ba645578b0955026ee7554889ae4c530bd7a3b6f688233d763e169f",
     "7a66d0896f2c4c2c9ac55670c71a9bc1bdbdfb4e8786ee5137cea1d0a05b6f20", "cN/yQ7+k7pg=",
     "7114cd9afd1eade02f76703cc976c241246a2f26f5c4b7a3a0150ecc745da9f0"},
    {"02830212a32a47e68b98d477000bde08cb916f4d44ef49d47ccd4918d9aaabe9c8",
     "6e8c3da5f2fb0306a88d6bcd427cbfba0b9c7f4c930c43122a973d620ffa3036", "m2/QAsmwaA4=",
     "f1d6fb05da1225feeddd1cf4100128afe09c3c1aadbffbd5c8bd10d329ef8f40"},
    {"03f20a7e71c4b276753969e8b7e8b67e2dbafc3958d66ecba98dedc60a6615336d",
     "e9d174eff5708a0a41b32624f9b9cc97ef08f8931ed188ee58d5390cad2bf68e", "jgpUIjWFlVQ=",
     "c5677c533f17c30f79a40744b18085632b262c0c13d87f3848c385f1389f79a6"}
  ]

  # BRC-42, "For Testing Public Key Derivation".
  @public [
    {"583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c",
     "02c0c1e1a1f7d247827d1bcf399f0ef2deef7695c322fd91a01a91378f101b6ffc", "IBioA4D/OaE=",
     "03c1bf5baadee39721ae8c9882b3cf324f0bf3b9eb3fc1b8af8089ca7a7c2e669f"},
    {"2c378b43d887d72200639890c11d79e8f22728d032a5733ba3d7be623d1bb118",
     "039a9da906ecb8ced5c87971e9c2e7c921e66ad450fd4fc0a7d569fdb5bede8e0f", "PWYuo9PDKvI=",
     "0398cdf4b56a3b2e106224ff3be5253afd5b72de735d647831be51c713c9077848"},
    {"d5a5f70b373ce164998dff7ecd93260d7e80356d3d10abf928fb267f0a6c7be6",
     "02745623f4e5de046b6ab59ce837efa1a959a8f28286ce9154a4781ec033b85029", "X9pnS+bByrM=",
     "0273eec9380c1a11c5a905e86c2d036e70cbefd8991d9a0cfca671f5e0bbea4a3c"},
    {"46cd68165fd5d12d2d6519b02feb3f4d9c083109de1bfaa2b5c4836ba717523c",
     "031e18bb0bbd3162b886007c55214c3c952bb2ae6c33dd06f57d891a60976003b1", "+ktmYRHv3uQ=",
     "034c5c6bf2e52e8de8b2eb75883090ed7d1db234270907f1b0d1c2de1ddee5005d"},
    {"7c98b8abd7967485cfb7437f9c56dd1e48ceb21a4085b8cdeb2a647f62012db4",
     "03c8885f1e1ab4facd0f3272bb7a48b003d2e608e1619fb38b8be69336ab828f37", "PPfDTTcl1ao=",
     "03304b41cfa726096ffd9d8907fe0835f888869eda9653bca34eb7bcab870d3779"}
  ]

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  for {{sender_pub, recipient_priv, invoice, expected}, i} <- Enum.with_index(@private, 1) do
    test "BRC-42 private vector #{i}" do
      assert {:ok, child} =
               Brc42.private_child(
                 unhex(unquote(recipient_priv)),
                 unhex(unquote(sender_pub)),
                 unquote(invoice)
               )

      assert hex(child) == unquote(expected)
    end
  end

  for {{sender_priv, recipient_pub, invoice, expected}, i} <- Enum.with_index(@public, 1) do
    test "BRC-42 public vector #{i}" do
      assert {:ok, child} =
               Brc42.public_child(
                 unhex(unquote(sender_priv)),
                 unhex(unquote(recipient_pub)),
                 unquote(invoice)
               )

      assert hex(child) == unquote(expected)
    end
  end

  test "the two halves meet: a private child's public key is the public child" do
    a = :crypto.strong_rand_bytes(32)
    b = :crypto.strong_rand_bytes(32)

    {:ok, child_priv} = Brc42.private_child(b, Brc42.public_key(a), "2-test-1")
    {:ok, child_pub} = Brc42.public_child(a, Brc42.public_key(b), "2-test-1")

    assert Brc42.public_key(child_priv) == child_pub
  end

  test "@bsv/sdk's BRC-3 compliance vector verifies through anyone's public child" do
    # ProtoWallet('anyone').verifySignature({data: 'BRC-3 Compliance Validated!',
    # protocolID: [2, 'BRC3 Test'], keyID: '42', counterparty: 0294c4…}) is true.
    der =
      :erlang.list_to_binary([
        48,
        68,
        2,
        32,
        43,
        34,
        58,
        156,
        219,
        32,
        50,
        70,
        29,
        240,
        155,
        137,
        88,
        60,
        200,
        95,
        243,
        198,
        201,
        21,
        56,
        82,
        141,
        112,
        69,
        196,
        170,
        73,
        156,
        6,
        44,
        48,
        2,
        32,
        118,
        125,
        254,
        201,
        44,
        87,
        177,
        170,
        93,
        11,
        193,
        134,
        18,
        70,
        9,
        31,
        234,
        27,
        170,
        177,
        54,
        96,
        181,
        140,
        166,
        196,
        144,
        14,
        230,
        118,
        106,
        105
      ])

    counterparty = unhex("0294c479f762f6baa97fbcd4393564c1d7bd8336ebd15928135bbcf575cd1a71a1")

    # BRC-43: the protocol name lowercased, "<level>-<protocol>-<keyID>".
    assert {:ok, child} =
             Brc42.public_child(Brc42.anyone_private(), counterparty, "2-brc3 test-42")

    assert Curvy.verify(der, "BRC-3 Compliance Validated!", child, hash: :sha256) == true
    refute Curvy.verify(der, "BRC-3 Compliance Validated?", child, hash: :sha256)
  end

  test "anyone is the scalar 1, whose public key is G" do
    assert hex(Brc42.anyone_public()) ==
             "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
  end

  test "a key off the curve, or an out-of-range scalar, is :error" do
    priv = :crypto.strong_rand_bytes(32)
    assert Brc42.public_child(priv, <<2, 0::256>>, "x") == :error
    assert Brc42.private_child(priv, <<4, 0::512>>, "x") == :error
    assert Brc42.shared_secret(<<0::256>>, Brc42.anyone_public()) == :error
    refute Brc42.valid_private?(<<0::256>>)
    refute Brc42.valid_private?(<<-1::256>>)
  end
end
