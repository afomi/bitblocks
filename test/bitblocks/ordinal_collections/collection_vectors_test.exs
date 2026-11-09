defmodule Bitblocks.OrdinalCollections.CollectionVectorsTest do
  @moduledoc """
  #77 and #79: the RelayX and Rare Candy collections beyond Rexxies, each
  proven from real mainnet transactions (test/fixtures/collections, each
  hashing to its txid), run through the same engine as Rexxies and Tardinians.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.{Item, RareCandy, RunJig}

  @dir "test/fixtures/collections"

  defp hex(txid), do: File.read!(Path.join(@dir, "#{txid}.hex")) |> String.trim()

  defp decode(txid) do
    {:ok, tx} = RawTx.parse(hex(txid))
    tx
  end

  defp publish_real(txid, height), do: publish({txid, hex(txid)}, height)

  defp config(slug), do: OrdinalCollections.config_for(OrdinalCollections.known()[slug])

  test "every fixture hashes to its txid" do
    for file <- File.ls!(@dir), Path.extname(file) == ".hex" do
      txid = Path.rootname(file)
      bytes = Base.decode16!(hex(txid), case: :mixed)

      assert :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
             |> :binary.bin_to_list()
             |> Enum.reverse()
             |> :erlang.list_to_binary()
             |> Base.encode16(case: :lower) == txid
    end
  end

  describe "RelayX collections (#79)" do
    # slug => {first mint, block height}
    @first_mints %{
      "pixmoji" => {"fc7d422c144bf6136318e2a7f64b01e019ba1cb1789afa1eca830812f4f1fd9e", 731_286},
      "glossy-spheres" =>
        {"969c4483fff4e686c8b955a16314e26372e9babb838fe01f21129a9732eddc9b", 734_588}
    }

    for {slug, {mint, height}} <- @first_mints do
      @slug slug
      @mint mint
      @height height

      test "#{slug}: the first mint spends the class and creates one NFT, its image the mint's B:// file" do
        config = config(@slug)

        assert {:ok, [item], [next]} = RunJig.mint(decode(@mint), @mint, config.id, config)
        assert item.vout == 3
        assert item.name == nil
        assert item.image_txid == @mint
        assert is_binary(item.owner)
        assert next == "#{@mint}_2"
      end

      test "#{slug}: a sync walks the class chain from its location to the first mint" do
        cid = OrdinalCollections.known()[@slug]
        publish_real(@mint, @height)
        spend(cid, @mint, 0)

        assert %{mints: 1, items: 1, complete: true} = OrdinalCollections.sync(cid, [])

        item = Repo.get_by!(Item, collection_id: cid, origin: "#{@mint}_3")
        assert OrdinalCollections.image_path(item) == "/b/#{@mint}"
        assert %{name: _, source: "RelayX", items: 1} = OrdinalCollections.get_collection(@slug)
      end
    end

    test "PixMoji's updateMetadata call carries the class chain on with no items" do
      update = "b1b7825df1b19aaa3d0243bf8cc763e13441c51a7973f65c1b472bb13130274c"
      tx = decode(update)
      [%BSV.TxIn{outpoint: link_op} | _] = tx.inputs
      link = "#{BSV.OutPoint.get_txid(link_op)}_#{link_op.vout}"

      # No B:// output here, so the payload is output 0 and the class output 1.
      assert {:ok, 0, _} = RunJig.payload(tx)
      assert {:ok, [], ["#{update}_1"]} == RunJig.mint(tx, update, link, config("pixmoji"))
    end
  end

  describe "Rare Candy (#77)" do
    @collection "b9a47ebfeba619a97ddf44ef5bd4b3546bf05bf52391cd828154b19896811b52"
    @mint "0ef416e3b3f280b357e8a16e2f16cdda35f749cb8545ee031a21e39c030e9a7f"
    @sale "fed262c04213a363910f12417c70fae0378a1a1a58a772fa15de7b40d3e78be9"

    # Each collection tx declares the mint outpoint its config walks from.
    test "each configured collection's link is the mint outpoint its collection tx declares" do
      for slug <- ["planetary-skies", "astro-apes", "oni-society", "fox-syndicate"] do
        config = config(slug)
        [txid, "0"] = String.split(config.id, "_")

        {:ok, %{content: json, media_type: "application/json", filename: "dogefile"}} =
          txid |> decode() |> Bitblocks.Bitcom.BFile.parse()

        declared = Jason.decode!(json)["mint_outpoint"]
        assert config.link in RareCandy.mint_outpoints(declared), slug
        assert config.protocol == RareCandy
      end
    end

    test "the Planetary Skies mint: 99 items locked to the collection, named and traited on chain" do
      config = config("planetary-skies")
      tx = decode(@mint)

      assert {:ok, items, []} = RareCandy.mint(tx, @mint, config.link, config)
      assert length(items) == 99
      assert Enum.map(items, & &1.vout) == Enum.to_list(0..98)

      first = hd(items)
      assert first.name == "Planetary Skies #1"
      assert first.owner == "1GSoUbqkb6w3pEHgPk9T2pb9nA1s3ina76"

      assert first.image_txid ==
               "3d313c2216ea70b3c396f4a4bf311db77c145af9e97a8bfa078dad174b1435fc"

      assert %{"name" => "Background", "value" => "Quantum Ice"} in first.traits
    end

    test "the lock is a claim: the same outputs don't mint without the mint outpoint" do
      config = config("planetary-skies")
      assert :no == RareCandy.mint(decode(@mint), @mint, funding_outpoint(), config)

      other = %{config | id: "#{String.duplicate("a", 64)}_0"}
      assert :no == RareCandy.mint(decode(@mint), @mint, config.link, other)
    end

    test "a sync walks from the declared mint outpoint and indexes every item" do
      config = config("planetary-skies")
      publish_real(@collection, 717_159)
      publish_real(@mint, 717_087)
      spend(config.link, @mint, 0)

      assert %{mints: 1, items: 99, complete: true} = OrdinalCollections.sync(config.id, [])

      item = Repo.get_by!(Item, collection_id: config.id, origin: "#{@mint}_18")
      assert item.name == "Planetary Skies #19"
      assert OrdinalCollections.image_path(item) == "/b/#{item.image_txid}"

      assert %{items: 99, source: "Rare Candy"} =
               OrdinalCollections.get_collection("planetary-skies")
    end

    test "a market sale lands the item in the output after the seller's payment" do
      sale = decode(@sale)

      # Input 0 reveals the collection txid; output 1 carries the lock to the buyer.
      assert {:ok, "#{@sale}_1"} == RareCandy.landing(sale, @sale, 0, fn _ -> :error end)
      assert RareCandy.owner(Enum.at(sale.outputs, 1)) == "1DvY4UJgWKqyFr2WVVJpzUiy2SrgivWtDb"

      assert {:unknown, _} = RareCandy.landing(sale, @sale, 1, fn _ -> :error end)
    end

    test "a spend that carries no lock on ends the item's trail" do
      reveal = %BSV.Script{
        chunks: [<<0x30>>, <<0x02>>, Base.decode16!(@collection, case: :lower)]
      }

      burn = %BSV.Tx{
        inputs: [%BSV.TxIn{outpoint: %BSV.OutPoint{hash: <<0::256>>, vout: 0}, script: reveal}],
        outputs: [p2pkh(address(), 400)]
      }

      assert {:ended, reason} = RareCandy.landing(burn, "t", 0, fn _ -> :error end)
      assert reason =~ "no output carrying its Rare Candy lock"
    end

    test "states its own membership rule" do
      assert RareCandy.rule() =~ "hash160 of the collection txid"
      assert OrdinalCollections.verification(config("oni-society").id).rule == RareCandy.rule()
    end
  end
end
