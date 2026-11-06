defmodule BitblocksWeb.Api.BapControllerTest do
  # GET /api/v1/bap: identities as the chain says, read-only and public (#32).
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.{Aip, Bap, Repo}

  setup do
    privkey = BSV.PrivKey.new()
    other = BSV.PrivKey.new()
    root = address(privkey)
    declared = address(other)
    bap_id = Bap.bap_id_of(root)

    publish([signed([Bap.prefix(), "ID", bap_id, declared], privkey, root)], 700_000)

    publish(
      [signed([Bap.prefix(), "ALIAS", bap_id, ~s({"name":"Ada"})], other, declared)],
      700_010
    )

    hash = String.duplicate("a", 64)
    publish([signed([Bap.prefix(), "ATTEST", hash, "0"], other, declared)], 700_020)

    %{bap_id: bap_id, root: root, declared: declared, hash: hash}
  end

  defp address(privkey) do
    privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()
  end

  defp signed(fields, privkey, address) do
    signature =
      BSV.Message.sign(IO.iodata_to_binary([<<0x6A>>, fields, "|"]), privkey, encoding: :raw)

    %BSV.TxOut{
      satoshis: 0,
      script: %BSV.Script{
        chunks:
          [:OP_FALSE, :OP_RETURN] ++
            fields ++ ["|", Aip.prefix(), "BITCOIN_ECDSA", address, signature]
      }
    }
  end

  defp publish(outputs, height) do
    block = block_fixture(%{height: height})
    in_tx = %BSV.TxIn{outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0}}
    tx = %BSV.Tx{inputs: [in_tx], outputs: outputs}

    %{
      txid: BSV.Tx.get_txid(tx),
      raw: Bitblocks.OrdinalFixtures.raw_tx_hex(tx),
      block_height: height,
      block_hash: block.hash,
      aip_signers: ["signed"],
      protocols: ["AIP"]
    }
    |> transaction_fixture()
    |> Bap.index()
  end

  test "GET /api/v1/bap/:bap_id answers the identity", %{conn: conn} = ctx do
    data = conn |> get(~p"/api/v1/bap/#{ctx.bap_id}") |> json_response(200) |> Map.get("data")

    assert data["bap_id"] == ctx.bap_id
    assert data["root_address"] == ctx.root
    assert data["current_address"] == ctx.declared
    assert data["first_record"]["block_height"] == 700_000
    assert data["rotations"] == []
    assert data["current_profile"]["profile"] == %{"name" => "Ada"}
    assert data["rejected"] == []
    assert Map.has_key?(data["as_of"], "first_record_final")
    refute Map.has_key?(data, "keys")
  end

  test "attestations answers what the identity made", %{conn: conn} = ctx do
    data =
      conn
      |> get(~p"/api/v1/bap/#{ctx.bap_id}/attestations")
      |> json_response(200)
      |> Map.get("data")

    hash = ctx.hash
    assert [%{"attestation_hash" => ^hash, "revoked" => false}] = data["made"]
  end

  test "GET /api/v1/bap?address= finds the identities it signs for", %{conn: conn} = ctx do
    bap_id = ctx.bap_id

    assert %{"data" => [%{"bap_id" => ^bap_id, "current" => true}]} =
             conn |> get(~p"/api/v1/bap?#{[address: ctx.declared]}") |> json_response(200)

    assert %{"data" => []} =
             conn |> get(~p"/api/v1/bap?#{[address: "1Nobody"]}") |> json_response(200)
  end

  test "an unknown identity is a 404, and no address a 400", %{conn: conn} do
    assert conn |> get(~p"/api/v1/bap/2Ny5b5yyzSedzcnhK4H3w2xS9iR3") |> json_response(404)
    assert conn |> get(~p"/api/v1/bap/2Ny5b5yyzSedzcnhK4H3w2xS9iR3/attestations") |> response(404)
    assert conn |> get(~p"/api/v1/bap") |> json_response(400)
  end

  test "no record is ever written by a read", %{conn: conn} = ctx do
    before = Repo.aggregate(Bitblocks.Bap.Record, :count)
    conn |> get(~p"/api/v1/bap/#{ctx.bap_id}") |> json_response(200)
    assert Repo.aggregate(Bitblocks.Bap.Record, :count) == before
  end
end
