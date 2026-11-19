defmodule Bitblocks.Interop.Brc77Test do
  @moduledoc """
  BRC-77 against the reference SDK.

  `test/support/fixtures/brc/brc77_sdk_v1.json` holds envelopes `@bsv/sdk`
  2.4.0's `SignedMessage.sign` wrote, for anyone and for one recipient, with
  the keys of the SDK's own SignedMessage tests (signer 15, recipient 21).
  Each must verify here, and since RFC 6979 makes the signature a function of
  the key and message, our signer must write the same envelope byte for byte
  from the same key ID. The other way round was checked once on 2026-11-19:
  envelopes from `sign/4` verify with the SDK's `SignedMessage.verify`.

  The two hex examples in BRC-77 itself don't give the message they sign, so
  only their framing can be read (the last describe).
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Interop.Brc77

  @path Path.expand("../../support/fixtures/brc/brc77_sdk_v1.json", __DIR__)
  @external_resource @path
  @fixture @path |> File.read!() |> Jason.decode!()

  @signer <<15::big-size(256)>>
  @recipient <<21::big-size(256)>>
  @wrong <<22::big-size(256)>>
  @small <<1, 2, 4, 8, 16, 32>>

  defp unhex(hex), do: Base.decode16!(hex, case: :mixed)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  test "the fixture's keys are the SDK tests' keys" do
    assert hex(Brc77.public_key(@signer)) == @fixture["signer_identity_key"]
    assert hex(Brc77.public_key(@recipient)) == @fixture["recipient_identity_key"]

    # The public keys the SDK's error messages name for 21 and 22.
    assert hex(Brc77.public_key(@recipient)) ==
             "02352bbf4a4cdd12564f93fa332ce333301d9ad40271f8107181340aef25be59d5"

    assert hex(Brc77.public_key(@wrong)) ==
             "03421f5fc9a21065445c96fdb91c0c1e2f2431741c72713b4b99ddcb316f31e9fc"
  end

  describe "@bsv/sdk 2.4.0's envelopes" do
    for vector <- @fixture["vectors"] do
      @vector vector

      test "#{vector["id"]}: verifies, and our signer writes the same bytes" do
        message = unhex(@vector["message_hex"])
        envelope = unhex(@vector["envelope_hex"])
        signer = unhex(@fixture["signer_identity_key"])

        {:ok, parts} = Brc77.parse(envelope)
        assert parts.signer == signer

        recipient =
          if @vector["recipient"] == "anyone", do: :anyone, else: unhex(@vector["recipient"])

        assert parts.recipient == recipient
        assert Brc77.sign(message, @signer, parts.key_id, recipient) == envelope

        case recipient do
          :anyone ->
            assert Brc77.verify(message, envelope) == {:ok, signer}
            # Any key may check an envelope for anyone, as the SDK allows.
            assert Brc77.verify(message, envelope, @wrong) == {:ok, signer}

          _ ->
            assert Brc77.verify(message, envelope, @recipient) == {:ok, signer}
            assert Brc77.verify(message, envelope) == {:error, :not_anyone}
            assert Brc77.verify(message, envelope, @wrong) == {:error, :wrong_recipient}
        end

        tampered = message <> <<0>>
        key = if recipient == :anyone, do: Brc77.verify(tampered, envelope), else: nil

        if key,
          do: assert(key == {:error, :signature_fails}),
          else: assert(Brc77.verify(tampered, envelope, @recipient) == {:error, :signature_fails})
      end
    end
  end

  describe "as the SDK's SignedMessage tests" do
    test "signs a message for a recipient" do
      envelope = Brc77.sign(@small, @signer, Brc77.key_id(), Brc77.public_key(@recipient))
      assert {:ok, _} = Brc77.verify(@small, envelope, @recipient)
    end

    test "signs a message for anyone" do
      envelope = Brc77.sign(@small, @signer, Brc77.key_id())
      assert {:ok, _} = Brc77.verify(@small, envelope)
    end

    test "fails to verify a message with a wrong version" do
      <<_, rest::binary>> = Brc77.sign(@small, @signer, Brc77.key_id())
      assert Brc77.verify(@small, <<1, rest::binary>>) == {:error, :malformed_envelope}
    end

    test "fails to verify a message with no verifier when one is required" do
      envelope = Brc77.sign(@small, @signer, Brc77.key_id(), Brc77.public_key(@recipient))
      assert Brc77.verify(@small, envelope) == {:error, :not_anyone}
    end

    test "fails to verify a message with a wrong verifier" do
      envelope = Brc77.sign(@small, @signer, Brc77.key_id(), Brc77.public_key(@recipient))
      assert Brc77.verify(@small, envelope, @wrong) == {:error, :wrong_recipient}
    end

    test "a tampered message fails, for anyone and for a recipient" do
      tampered = <<1, 2, 4, 8, 16, 64>>
      anyone = Brc77.sign(@small, @signer, Brc77.key_id())
      named = Brc77.sign(@small, @signer, Brc77.key_id(), Brc77.public_key(@recipient))

      assert Brc77.verify(tampered, anyone) == {:error, :signature_fails}
      assert Brc77.verify(tampered, named, @recipient) == {:error, :signature_fails}
    end
  end

  test "each key ID is fresh, so two signatures of one message differ and both verify" do
    a = Brc77.sign(@small, @signer, Brc77.key_id())
    b = Brc77.sign(@small, @signer, Brc77.key_id())

    refute a == b
    assert {:ok, _} = Brc77.verify(@small, a)
    assert {:ok, _} = Brc77.verify(@small, b)
  end

  test "a recipient off the curve is refused when signing" do
    assert_raise ArgumentError, fn ->
      Brc77.sign(@small, @signer, Brc77.key_id(), <<2, 0::256>>)
    end
  end

  describe "BRC-77's own hex examples (no message given, so framing only)" do
    test "for a recipient" do
      envelope =
        unhex(
          "42423301" <>
            "032e5bd6b837cfb30208bbb1d571db9ddf2fb1a7b59fb4ed2a31af632699f770a1" <>
            "02e5e1a150745253aff65cdbcef722873110d89c396223e3d8715f018e72f7d4f8" <>
            "8166f775e9128dfea9ddb8fc92c655cfaae6795e18911d7d1b6d981ac8664e36" <>
            "30450221009fd5c15bb289bd3a26454131b269b4f550f32dca4c21fde29cef3ebaa913363c022052d421eae633c363b1dad674a1da4821c885425cc636147388b8b08b439721be"
        )

      assert {:ok, parts} = Brc77.parse(envelope)

      assert hex(parts.signer) ==
               "032e5bd6b837cfb30208bbb1d571db9ddf2fb1a7b59fb4ed2a31af632699f770a1"

      assert hex(parts.recipient) ==
               "02e5e1a150745253aff65cdbcef722873110d89c396223e3d8715f018e72f7d4f8"

      assert hex(parts.key_id) ==
               "8166f775e9128dfea9ddb8fc92c655cfaae6795e18911d7d1b6d981ac8664e36"

      assert byte_size(parts.der) == 71
    end

    test "for anyone" do
      envelope =
        unhex(
          "42423301" <>
            "032e5bd6b837cfb30208bbb1d571db9ddf2fb1a7b59fb4ed2a31af632699f770a1" <>
            "00" <>
            "e8ff1624ede8d6ca5303badb68dec8f226284385bed3bc7c19b578a905866587" <>
            "3045022100b304d38e25106c732f0247fab70b9cf47d5434c08d7a94ef4ad7069bae9a9a0e02202f4e3b4e5d7d698cfebe64f643dbcddc1631e6f09aece0850613f602ec4d50e6"
        )

      assert {:ok, %{recipient: :anyone} = parts} = Brc77.parse(envelope)

      assert hex(parts.key_id) ==
               "e8ff1624ede8d6ca5303badb68dec8f226284385bed3bc7c19b578a905866587"
    end
  end
end
