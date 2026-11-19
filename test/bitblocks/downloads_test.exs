defmodule Bitblocks.DownloadsTest do
  # Bulk downloads, the free quote (https://github.com/afomi/bitblocks/issues/111):
  # sizes from blocks.size, bounded by complete_through, missing sizes named.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Downloads

  @gib 1_073_741_824

  defp chain(sizes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {size, height} <- Enum.with_index(sizes) do
      block = block_fixture(%{height: height, size: size, sync_state: "completed"})

      # Every block's object is in the store but block 0's.
      if height > 0 do
        block |> Ecto.Changeset.change(raw_object_stored_at: now) |> Bitblocks.Repo.update!()
      end
    end
  end

  describe "quote/4" do
    test "sums stored block sizes over the range, one file per block" do
      chain([285, @gib, @gib, 1_000])
      block_fixture(%{height: 4, size: 5_000, sync_state: "header_only"})

      assert {:ok, quote} = Downloads.quote(0, 3, "raw")

      assert quote.from == 0
      assert quote.to == 3
      assert quote.data == "raw"
      assert quote.format == "bin"
      assert quote.complete_through == 3
      assert quote.blocks == 4
      assert quote.files == 4
      assert quote.bytes == 2 * @gib + 1_285
      assert quote.gib == 2.0
      assert quote.bytes_exact
      assert quote.sizes_missing == 0
      assert quote.sizes_missing_heights == []
      assert quote.not_in_store == 1
    end

    test "takes heights as strings, with separators" do
      chain([100, 200, 300])

      assert {:ok, %{from: 1, to: 2, bytes: 500}} = Downloads.quote("1", " 2 ", "raw")
      assert {:ok, %{bytes: 600}} = Downloads.quote("0", "2", :raw, format: "bin")
    end

    test "refuses a range above complete_through, naming that height" do
      chain([100, 200])
      block_fixture(%{height: 2, size: 300, sync_state: "header_only"})

      assert {:error, {:above_complete_through, 1}} = Downloads.quote(0, 2, "raw")

      assert Downloads.error_message({:above_complete_through, 1_234_567}) =~ "1,234,567"
      assert Downloads.error_code({:above_complete_through, 1}) == "above_complete_through"
    end

    test "with nothing complete, refuses every range" do
      block_fixture(%{height: 0, size: 285, sync_state: "header_only"})

      assert {:error, {:above_complete_through, -1}} = Downloads.quote(0, 0, "raw")
      assert Downloads.error_message({:above_complete_through, -1}) =~ "No blocks are complete"
    end

    test "reports blocks with no stored size rather than guessing" do
      chain([100, nil, 300, nil])

      assert {:ok, quote} = Downloads.quote(0, 3, "raw")

      assert quote.bytes == 400
      refute quote.bytes_exact
      assert quote.sizes_missing == 2
      assert quote.sizes_missing_heights == [1, 3]
      assert quote.price_usd == nil
    end

    test "refuses data we can't produce yet, and unknown data or formats" do
      chain([100])

      assert {:error, {:coming, "tx_json"}} = Downloads.quote(0, 0, "tx_json")
      assert {:error, {:coming, "data_pack"}} = Downloads.quote(0, 0, "data_pack")
      assert {:error, :unknown_data} = Downloads.quote(0, 0, "csv")
      assert {:error, :unknown_data} = Downloads.quote(0, 0, nil)
      assert {:error, :unknown_format} = Downloads.quote(0, 0, "raw", format: "hex")

      assert Downloads.error_message({:coming, "tx_json"}) =~ "Transaction JSON"
    end

    test "refuses a range that isn't two whole numbers in order" do
      for {from, to} <- [{2, 1}, {-1, 3}, {"a", 3}, {"1.5", 3}, {nil, 3}] do
        assert {:error, :invalid_range} = Downloads.quote(from, to, "raw", complete_through: 10)
      end
    end
  end

  describe "price" do
    setup do
      previous = Application.get_env(:bitblocks, Downloads)
      on_exit(fn -> restore(previous) end)
    end

    defp restore(nil), do: Application.delete_env(:bitblocks, Downloads)
    defp restore(value), do: Application.put_env(:bitblocks, Downloads, value)

    test "is nil, on request, unless configured" do
      chain([@gib])
      Application.delete_env(:bitblocks, Downloads)

      assert Downloads.price_usd_per_gib() == nil
      assert {:ok, %{price_usd: nil}} = Downloads.quote(0, 0, "raw")
    end

    test "follows the configured price per GiB once set" do
      chain([@gib, div(@gib, 2)])
      Application.put_env(:bitblocks, Downloads, price_usd_per_gib: "3")

      assert {:ok, %{price_usd: price}} = Downloads.quote(0, 1, "raw")
      assert Decimal.equal?(price, Decimal.new("4.50"))
    end
  end

  test "data_options/0 lists raw as available and the rest as coming" do
    assert [%{id: "raw", available: true, formats: [%{id: "bin"}]} | rest] =
             Downloads.data_options()

    assert Enum.map(rest, &{&1.id, &1.available}) == [{"tx_json", false}, {"data_pack", false}]
  end
end
