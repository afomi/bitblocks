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

    test "at $1.00 a GiB, is the billable GiB times the rate, to the cent" do
      # 2.505 GiB rounds half up to 2.51.
      chain([@gib, @gib, div(@gib * 505, 1000) + 1])
      Application.put_env(:bitblocks, Downloads, price_usd_per_gib: "1.00")

      assert {:ok, quote} = Downloads.quote(0, 2, "raw")
      assert Decimal.equal?(quote.price_usd_per_gib, Decimal.new("1.00"))
      assert Decimal.equal?(quote.billable_gib, Decimal.new("2.51"))
      assert Decimal.equal?(quote.price_usd, Decimal.new("2.51"))
      assert Downloads.format_usd(quote.price_usd) == "$2.51"
    end

    test "a missing size gives no price, though the rate is set" do
      chain([@gib, nil])
      Application.put_env(:bitblocks, Downloads, price_usd_per_gib: 1.0)

      assert {:ok, quote} = Downloads.quote(0, 1, "raw")
      assert quote.price_usd == nil
      assert Decimal.equal?(quote.price_usd_per_gib, Decimal.new("1.0"))
    end

    test "billable_gib/1 never reads a small range as free" do
      assert Decimal.equal?(Downloads.billable_gib(0), 0)
      assert Decimal.equal?(Downloads.billable_gib(1), Decimal.new("0.01"))
      assert Decimal.equal?(Downloads.billable_gib(div(@gib, 2)), Decimal.new("0.50"))
      assert Downloads.format_usd(Decimal.new("12345.5")) == "$12,345.50"
    end
  end

  describe "presets/1" do
    test "clips each range to complete_through, and marks those out of reach" do
      presets = Map.new(Downloads.presets(300_000), &{&1.id, &1})

      assert %{from: 0, to: 99_999, clipped: false, available: true} = presets["first_100k"]
      assert %{from: 0, to: 300_000, available: true} = presets["all"]
      assert %{from: 210_000, to: 300_000, clipped: true} = presets["second_halving"]
      assert %{available: false} = presets["bsv"]

      assert %{to: 99_999} = Downloads.preset("first_100k", 1_000_000)
      assert Downloads.preset("nope", 10) == nil
      assert Enum.all?(Downloads.presets(-1), &(not &1.available))
    end
  end

  describe "size_bands/1" do
    setup do
      Downloads.clear_size_bands()
      on_exit(&Downloads.clear_size_bands/0)
    end

    test "sums each band up to complete_through, from blocks only" do
      chain([100, 200, nil])

      assert %{complete_through: 2, band_size: 50_000, bands: [band]} = Downloads.size_bands()
      assert %{from: 0, to: 2, blocks: 3, bytes: 300, bytes_exact: false, sizes_missing: 1} = band
      assert band.price_usd == nil

      assert %{bands: [_, %{from: 50_000, to: 60_000}]} =
               Downloads.size_bands(complete_through: 60_000)
    end

    test "is cached until cleared" do
      chain([100])
      assert %{bands: [%{bytes: 100}]} = Downloads.size_bands()

      block_fixture(%{height: 1, size: 50, sync_state: "completed"})
      assert %{complete_through: 0} = Downloads.size_bands()

      Downloads.clear_size_bands()
      assert %{complete_through: 1, bands: [%{bytes: 150}]} = Downloads.size_bands()
    end

    test "is empty with nothing complete" do
      assert %{complete_through: -1, bands: []} = Downloads.size_bands()
    end
  end

  test "data_options/0 lists raw as available and the rest as coming" do
    assert [%{id: "raw", available: true, formats: [%{id: "bin"}]} | rest] =
             Downloads.data_options()

    assert Enum.map(rest, &{&1.id, &1.available}) == [{"tx_json", false}, {"data_pack", false}]
  end
end
