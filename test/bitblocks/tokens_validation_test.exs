defmodule Bitblocks.TokensValidationTest do
  @moduledoc """
  BSV-21 transfer validation (#41), through the real ingest path: real txs
  built with `BSV.Tx`, stored by `TxIngest` (spends, then tokens), so the
  holders table only counts transfers that really move the token.

  The rule followed is the 1Sat BSV-21 spec
  (https://docs.1satordinals.com/fungible-tokens/bsv-21): a transfer's
  token inputs are the spent outputs of the same id; outputs above inputs make
  every transfer output of that id in the tx invalid; outputs below inputs
  are valid and the difference is burned.
  """
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [address: 0, p2pkh: 2, tx: 2, funding_outpoint: 0]

  alias Bitblocks.{Release, Tokens}
  alias Bitblocks.Chain.{RawBlock, TxIngest}
  alias Bitblocks.ProtocolRegistry.Instance

  setup do
    Bitblocks.ProtocolRegistry.get_protocol_by_name("BSV20") ||
      raise "BSV20 protocol not seeded — run mix ecto.migrate"

    %{block: block_fixture(%{height: 800_000}), alice: address(), bob: address()}
  end

  # A 1-sat output: a bsv-20 inscription, then a P2PKH lock to `owner`.
  defp token_out(fields, owner) do
    {:ok, %BSV.Address{pubkey_hash: pkh}} = BSV.Address.from_string(owner)
    body = Jason.encode!(Map.put(fields, "p", "bsv-20"))

    %BSV.TxOut{
      satoshis: 1,
      script: %BSV.Script{
        chunks:
          [:OP_FALSE, :OP_IF, "ord", :OP_1, "application/bsv-20", :OP_0, body, :OP_ENDIF] ++
            [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]
      }
    }
  end

  defp mint_out(amt, owner),
    do: token_out(%{"op" => "deploy+mint", "amt" => amt, "sym" => "T"}, owner)

  defp transfer_out(token_id, amt, owner),
    do: token_out(%{"op" => "transfer", "id" => token_id, "amt" => amt}, owner)

  defp ingest({txid, hex}, block) do
    :ok = TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :lower)), block)
    txid
  end

  defp mint(block, owner, amt \\ "1000") do
    txid = ingest(tx([funding_outpoint()], [mint_out(amt, owner)]), block)
    "#{txid}_0"
  end

  defp status(txid, vout) do
    Repo.one!(from(i in Instance, where: i.txid == ^txid and i.vout == ^vout)).state["status"]
  end

  test "a valid mint -> transfer moves the balance", %{block: block, alice: alice, bob: bob} do
    token_id = mint(block, alice)

    xfer =
      ingest(
        tx([token_id], [transfer_out(token_id, "250", bob), transfer_out(token_id, "750", alice)]),
        block
      )

    assert status(xfer, 0) == "valid"
    assert status(xfer, 1) == "valid"

    assert Tokens.token_holders(token_id) == [
             %{address: alice, balance: 750},
             %{address: bob, balance: 250}
           ]

    assert [%{validated: true, status: "valid"} | _] = Tokens.token_transfers(token_id)
  end

  test "a copied transfer inscription with no token input adds no holder",
       %{block: block, alice: alice, bob: bob} do
    token_id = mint(block, alice)

    # Bob funds the copy from a plain output whose tx is stored: known, no token.
    funding = ingest(tx([funding_outpoint()], [p2pkh(bob, 10_000)]), block)
    copy = ingest(tx(["#{funding}_0"], [transfer_out(token_id, "500", bob)]), block)

    assert status(copy, 0) == "invalid"
    assert Tokens.token_holders(token_id) == [%{address: alice, balance: 1000}]
    assert Tokens.balance_of(token_id, bob) == 0
    assert Tokens.unspent_outputs(bob) == []
    assert %{valid: 0, invalid: 1, pending: 0} = Tokens.transfer_counts(token_id)
  end

  test "a transfer whose outputs exceed its inputs is invalid and counted",
       %{block: block, alice: alice, bob: bob} do
    token_id = mint(block, alice)

    xfer =
      ingest(
        tx([token_id], [transfer_out(token_id, "900", bob), transfer_out(token_id, "300", alice)]),
        block
      )

    # The whole transfer is invalid, both outputs; the spent mint is burned.
    assert status(xfer, 0) == "invalid"
    assert status(xfer, 1) == "invalid"
    assert Tokens.token_holders(token_id) == []
    assert %{valid: 0, invalid: 2, pending: 0} = Tokens.transfer_counts(token_id)

    assert [%{validated: false, status: "invalid", reason: "outputs exceed inputs"} | _] =
             Tokens.token_transfers(token_id)
  end

  test "outputs below inputs are valid and the rest is burned", %{
    block: block,
    alice: alice,
    bob: bob
  } do
    token_id = mint(block, alice)
    xfer = ingest(tx([token_id], [transfer_out(token_id, "600", bob)]), block)

    assert status(xfer, 0) == "valid"
    assert Repo.one!(from(i in Instance, where: i.txid == ^xfer)).state["burned"] == "400"
    assert Tokens.token_holders(token_id) == [%{address: bob, balance: 600}]
  end

  test "a transfer of a different token id does not count as input",
       %{block: block, alice: alice, bob: bob} do
    token_a = mint(block, alice)
    token_b = mint(block, alice)
    xfer = ingest(tx([token_a], [transfer_out(token_b, "1000", bob)]), block)

    assert status(xfer, 0) == "invalid"
    assert Tokens.token_holders(token_b) == [%{address: alice, balance: 1000}]
  end

  test "a transfer indexed before its input is pending, then valid once the input is indexed",
       %{block: block, alice: alice, bob: bob} do
    {mint_txid, _} = mint_tx = tx([funding_outpoint()], [mint_out("1000", alice)])
    token_id = "#{mint_txid}_0"

    # Out of order: the transfer, and a transfer of that, before the mint.
    xfer = ingest(tx([token_id], [transfer_out(token_id, "1000", bob)]), block)
    onward = ingest(tx(["#{xfer}_0"], [transfer_out(token_id, "1000", alice)]), block)

    assert status(xfer, 0) == "pending"
    assert status(onward, 0) == "pending"
    assert Tokens.token_holders(token_id) == []
    assert [%{validated: false, status: "pending"} | _] = Tokens.token_transfers(token_id)

    ingest(mint_tx, block)

    assert status(xfer, 0) == "valid"
    assert status(onward, 0) == "valid"
    assert Tokens.token_holders(token_id) == [%{address: alice, balance: 1000}]
  end

  test "the revalidation command is a dry run by default and settles rows with apply",
       %{block: block, alice: alice, bob: bob} do
    token_id = mint(block, alice)
    good = ingest(tx([token_id], [transfer_out(token_id, "1000", bob)]), block)
    funding = ingest(tx([funding_outpoint()], [p2pkh(bob, 10_000)]), block)
    copy = ingest(tx(["#{funding}_0"], [transfer_out(token_id, "5", bob)]), block)

    # Rows indexed before validation existed carry no status.
    Repo.update_all(from(i in Instance, where: i.txid in ^[good, copy]), set: [state: %{}])
    assert Tokens.token_holders(token_id) == []

    report = ExUnit.CaptureIO.with_io(fn -> Release.revalidate_token_transfers() end)
    assert {%{applied: false, changed: 2, valid: 1, invalid: 1, pending: 0}, out} = report
    assert out =~ "DRY RUN"
    assert status(good, 0) == nil

    {applied, _} =
      ExUnit.CaptureIO.with_io(fn -> Release.revalidate_token_transfers(apply: true) end)

    assert %{applied: true, changed: 2} = applied
    assert status(good, 0) == "valid"
    assert status(copy, 0) == "invalid"
    assert Tokens.token_holders(token_id) == [%{address: bob, balance: 1000}]
  end

  test "a mint with an unspent balance reports its holders", %{block: block, alice: alice} do
    token_id = mint(block, alice)

    assert %{holders: 1, validated: true} = Tokens.get_token(token_id)
    assert [%{holders: 1}] = Tokens.list_tokens()
  end
end
