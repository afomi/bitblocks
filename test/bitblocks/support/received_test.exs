defmodule Bitblocks.Support.ReceivedTest do
  # Donation totals (#74, docs/DONATION_ADDRESS.md): a gift counts, change doesn't.
  use ExUnit.Case, async: true

  alias Bitblocks.Support.Received

  setup do
    pubkey = BSV.PrivKey.new() |> BSV.PubKey.from_privkey()
    address = pubkey |> BSV.Address.from_pubkey() |> BSV.Address.to_string()
    key = BSV.PubKey.to_binary(pubkey)

    # A P2PKH unlock: a 71-byte signature push, then the key.
    unlock = <<71>> <> :binary.copy(<<1>>, 71) <> <<byte_size(key)>> <> key

    %{address: address, unlock: %{"scriptSig" => %{"hex" => Base.encode16(unlock)}}}
  end

  defp output(address, value),
    do: %{"value" => value, "scriptPubKey" => %{"addresses" => [address]}}

  @stranger %{"scriptSig" => %{"hex" => "00"}}

  test "counts each output paid to the address", %{address: address} do
    vout = [output(address, 0.5), output("1other", 2.0), output(address, 0.00001234)]

    assert Received.sats(address, [@stranger], vout) == 50_001_234
  end

  test "counts nothing from a tx that spends from the address: that is change", ctx do
    vout = [output("1payee", 1.0), output(ctx.address, 0.25)]

    assert Received.sats(ctx.address, [@stranger, ctx.unlock], vout) == 0
  end

  test "an input with no readable unlock counts as someone else's", %{address: address} do
    assert Received.sats(address, [%{"coinbase" => "04ff"}, %{}], [output(address, 1)]) ==
             100_000_000
  end
end
