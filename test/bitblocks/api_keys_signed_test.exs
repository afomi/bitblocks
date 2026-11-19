defmodule Bitblocks.ApiKeysSignedTest do
  @moduledoc "#121: a key bound to whoever signs a bitblocks challenge."
  use Bitblocks.DataCase, async: true

  alias Bitblocks.ApiKeys

  defp key(opts \\ []) do
    privkey = BSV.PrivKey.new()
    privkey = if opts[:uncompressed], do: %{privkey | compressed: false}, else: privkey

    address =
      privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

    %{privkey: privkey, address: address}
  end

  defp nonce, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp message(nonce),
    do: ApiKeys.challenge_message("https://bitblocks.test", nonce, ~U[2026-11-18 12:00:00Z])

  defp sign(message, %{privkey: privkey}), do: BSV.Message.sign(message, privkey)

  test "the message names the site, the nonce and when, one per line" do
    assert message("ab12") ==
             "Sign this to get a bitblocks API key bound to your key.\n" <>
               "Site: https://bitblocks.test\nNonce: ab12\nIssued: 2026-11-18T12:00:00Z"
  end

  test "binds the key to the address recovered from the signature" do
    signer = key()
    n = nonce()

    assert {:ok, api_key, token} = ApiKeys.issue_signed(message(n), sign(message(n), signer), n)
    assert api_key.address == signer.address
    assert api_key.scopes == []
    assert api_key.requests_per_minute == ApiKeys.trial_requests_per_minute()
    assert ApiKeys.verify(token).id == api_key.id
  end

  test "an uncompressed key recovers its own address" do
    signer = key(uncompressed: true)
    n = nonce()

    assert {:ok, api_key, _} = ApiKeys.issue_signed(message(n), sign(message(n), signer), n)
    assert api_key.address == signer.address
  end

  test "a challenge works once" do
    signer = key()
    n = nonce()
    sig = sign(message(n), signer)

    assert {:ok, _, _} = ApiKeys.issue_signed(message(n), sig, n)
    assert {:error, :challenge_used} = ApiKeys.issue_signed(message(n), sig, n)
  end

  test "signing again replaces the address's key" do
    signer = key()
    n1 = nonce()
    n2 = nonce()

    {:ok, first, first_token} = ApiKeys.issue_signed(message(n1), sign(message(n1), signer), n1)
    {:ok, second, second_token} = ApiKeys.issue_signed(message(n2), sign(message(n2), signer), n2)

    assert ApiKeys.verify(first_token) == nil
    assert ApiKeys.verify(second_token).id == second.id
    assert ApiKeys.signed_key(signer.address).id == second.id
    refute first.id == second.id
  end

  test "a replay that fails leaves the existing key working" do
    signer = key()
    n = nonce()
    sig = sign(message(n), signer)

    {:ok, _, token} = ApiKeys.issue_signed(message(n), sig, n)
    {:error, :challenge_used} = ApiKeys.issue_signed(message(n), sig, n)

    assert ApiKeys.verify(token)
  end

  test "a signature over another message recovers to someone else" do
    signer = key()
    n = nonce()
    wrong = sign(message(nonce()), signer)

    # Without an expected address, it binds to a key nobody holds.
    assert {:ok, api_key, _} = ApiKeys.issue_signed(message(n), wrong, n)
    refute api_key.address == signer.address

    n2 = nonce()

    assert {:error, {:wrong_signer, _}} =
             ApiKeys.issue_signed(message(n2), sign(message(nonce()), signer), n2,
               address: signer.address
             )
  end

  test "garbage is a bad signature" do
    n = nonce()

    assert {:error, :bad_signature} = ApiKeys.issue_signed(message(n), "not base64!", n)

    assert {:error, :bad_signature} =
             ApiKeys.issue_signed(message(n), Base.encode64(<<0::520>>), n)
  end

  test "an expected address that didn't sign is named" do
    signer = key()
    other = key()
    n = nonce()

    assert {:error, {:wrong_signer, recovered}} =
             ApiKeys.issue_signed(message(n), sign(message(n), signer), n, address: other.address)

    assert recovered == signer.address
  end
end
