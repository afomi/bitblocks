defmodule Bitblocks.Interop.StatementSignatureTest do
  # The key lives in application env, so these run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.Interop.{Brc77, StatementSignature}

  @statement ~s({"version":"bsv-payment-evidence/v1"})

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  # A key made for this test alone; no real key is ever used here.
  defp test_key do
    key = :crypto.strong_rand_bytes(32)
    if Bitblocks.Interop.Brc42.valid_private?(key), do: key, else: test_key()
  end

  defp with_key(value) do
    previous = Application.get_env(:bitblocks, :statement_signing_key)
    Application.put_env(:bitblocks, :statement_signing_key, value)
    :persistent_term.erase({StatementSignature, :warned})

    on_exit(fn ->
      Application.put_env(:bitblocks, :statement_signing_key, previous)
      :persistent_term.erase({StatementSignature, :warned})
    end)
  end

  describe "with no key" do
    setup do: with_key(nil)

    test "nothing is signed, and status says so" do
      assert StatementSignature.status() == :not_configured
      refute StatementSignature.configured?()
      assert StatementSignature.sign(@statement) == nil
    end

    test "an empty value is no key" do
      Application.put_env(:bitblocks, :statement_signing_key, "")
      assert StatementSignature.status() == :not_configured
    end
  end

  describe "with a key as hex" do
    setup do
      key = test_key()
      with_key(hex(key))
      %{key: key}
    end

    test "signs for anyone, and anyone checks it with the statement alone", %{key: key} do
      assert StatementSignature.status() == :configured

      signature = StatementSignature.sign(@statement)

      assert signature.scheme == "BRC-77"
      assert signature.recipient == "anyone"
      assert signature.signer == hex(Brc77.public_key(key))

      assert StatementSignature.verify(@statement, signature.envelope) ==
               {:ok, %{signer: signature.signer, recipient: "anyone"}}

      assert StatementSignature.verify(@statement, signature.envelope, signer: signature.signer) ==
               {:ok, %{signer: signature.signer, recipient: "anyone"}}
    end

    test "the envelope signs the exact bytes", _ctx do
      signature = StatementSignature.sign(@statement)
      changed = String.replace(@statement, "v1", "v2")

      assert StatementSignature.verify(changed, signature.envelope) == {:error, :signature_fails}

      assert StatementSignature.verify(@statement <> " ", signature.envelope) ==
               {:error, :signature_fails}
    end

    test "another signer than the one expected is named" do
      signature = StatementSignature.sign(@statement)
      other = hex(Brc77.public_key(test_key()))

      assert StatementSignature.verify(@statement, signature.envelope, signer: other) ==
               {:error, {:signer_mismatch, signature.signer}}
    end

    test "for a named verifier, only that verifier's key checks it" do
      verifier = test_key()
      verifier_pub = Brc77.public_key(verifier)

      signature = StatementSignature.sign(@statement, verifier_pub)
      assert signature.recipient == hex(verifier_pub)

      assert StatementSignature.verify(@statement, signature.envelope) == {:error, :not_anyone}

      assert StatementSignature.verify(@statement, signature.envelope, recipient_key: test_key()) ==
               {:error, :wrong_recipient}

      assert StatementSignature.verify(@statement, signature.envelope, recipient_key: verifier) ==
               {:ok, %{signer: signature.signer, recipient: hex(verifier_pub)}}
    end

    test "the envelope reads as bytes too" do
      signature = StatementSignature.sign(@statement)
      bytes = Base.decode16!(signature.envelope, case: :lower)

      assert {:ok, _} = StatementSignature.verify(@statement, bytes)
    end

    test "each signature takes its own key ID" do
      refute StatementSignature.sign(@statement).envelope ==
               StatementSignature.sign(@statement).envelope
    end
  end

  test "a key as WIF, compressed or not, mainnet or testnet, is the same key" do
    key = test_key()

    for {payload, version} <- [
          {key <> <<1>>, <<0x80>>},
          {key, <<0x80>>},
          {key <> <<1>>, <<0xEF>>}
        ] do
      with_key(B58.encode58_check!(payload, version))
      assert StatementSignature.status() == :configured
      assert StatementSignature.sign(@statement).signer == hex(Brc77.public_key(key))
    end
  end

  describe "with a key that isn't one" do
    for {label, value} <- [
          {"not hex or WIF", "not a key"},
          {"zero", String.duplicate("0", 64)},
          {"past the curve order", String.duplicate("f", 64)},
          {"too short", String.duplicate("a", 62)}
        ] do
      @value value
      test "#{label}: invalid, unsigned, and logged once without the value" do
        with_key(@value)

        assert StatementSignature.status() == :invalid

        log =
          capture_log(fn ->
            assert StatementSignature.sign(@statement) == nil
            assert StatementSignature.sign(@statement) == nil
          end)

        assert log =~ "STATEMENT_SIGNING_KEY is set but isn't a private key"
        refute log =~ @value
        assert length(String.split(log, "STATEMENT_SIGNING_KEY")) == 2
      end
    end
  end

  describe "parse_recipient/1" do
    test "absent is anyone" do
      assert StatementSignature.parse_recipient(nil) == {:ok, :anyone}
      assert StatementSignature.parse_recipient("") == {:ok, :anyone}
    end

    test "a compressed key on the curve, in either case" do
      pub = Brc77.public_key(test_key())
      assert StatementSignature.parse_recipient(hex(pub)) == {:ok, pub}
      assert StatementSignature.parse_recipient(String.upcase(hex(pub))) == {:ok, pub}
    end

    test "anything else is refused" do
      for value <- [
            "zz",
            hex(<<2, 0::256>>),
            hex(<<4, 0::512>>),
            "02" <> String.duplicate("g", 64),
            7
          ] do
        assert StatementSignature.parse_recipient(value) == :error
      end
    end
  end
end
