defmodule Bitblocks.Interop.CheckTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Chain.Beef
  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.Interop.{Check, Vectors}
  alias Bitblocks.RealHeaders

  @vectors Jason.decode!(Vectors.body())["vectors"]

  defp hex(id), do: Enum.find(@vectors, &(&1["id"] == id))["hex"]
  defp unhex(value), do: Base.decode16!(value, case: :lower)

  defp limit(bytes) do
    previous = Application.get_env(:bitblocks, :beef_verify_max_bytes)
    Application.put_env(:bitblocks, :beef_verify_max_bytes, bytes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :beef_verify_max_bytes, previous),
        else: Application.delete_env(:bitblocks, :beef_verify_max_bytes)
    end)
  end

  defp tx(tag) do
    <<1::little-32, 1, :crypto.hash(:sha256, <<tag::32>>)::binary, 0::little-32, 0,
      0xFFFFFFFF::little-32, 1, 1000::little-64, 1, 0x51, 0::little-32>>
  end

  test "takes hex in either case, with line breaks, and raw bytes alike" do
    RealHeaders.insert(973_110)
    value = hex("mainnet-v1")
    {head, tail} = String.split_at(value, 40)

    for input <- [value, String.upcase(value), head <> "\r\n " <> tail <> "\n", unhex(value)] do
      assert {:ok, %{status: :proven, format: "beef_v1"}} = Check.run(input)
    end
  end

  test "the limit is the API's, on the decoded BEEF" do
    assert Check.max_bytes() == 4_000_000

    bytes = unhex(hex("mainnet-v1"))
    limit(byte_size(bytes))
    assert {:ok, _} = Check.run(hex("mainnet-v1"))

    limit(byte_size(bytes) - 1)
    assert {:error, :too_large} = Check.run(hex("mainnet-v1"))
    assert {:error, :too_large} = Check.run(bytes)
  end

  test "a BEEF of exactly 4 MB is read, and one byte more isn't" do
    beef = fn size ->
      script = :binary.copy(<<0x51>>, size)

      raw =
        <<1::little-32, 1, :crypto.hash(:sha256, "big")::binary, 0::little-32, 0,
          0xFFFFFFFF::little-32, 1, 1000::little-64, 0xFE, size::little-32, script::binary,
          0::little-32>>

      Beef.encode([], [{raw, nil}])
    end

    overhead = byte_size(beef.(100_000)) - 100_000
    at_limit = beef.(4_000_000 - overhead)

    assert byte_size(at_limit) == 4_000_000
    assert {:ok, %{status: :unknown}} = Check.run(at_limit)
    assert {:ok, %{status: :unknown}} = at_limit |> Base.encode16() |> Check.run()

    over = beef.(4_000_001 - overhead)
    assert {:error, :too_large} = Check.run(over)
    assert {:error, :too_large} = over |> Base.encode16() |> Check.run()
  end

  test "input far past the limit is refused unread" do
    limit(16)

    assert {:error, :too_large} = Check.run(String.duplicate(" ", Check.max_input_bytes() + 1))
    assert {:error, :too_large} = Check.run(String.duplicate("zz", Check.max_input_bytes()))
  end

  test "what isn't BEEF gets a fixed answer" do
    assert {:error, :empty} = Check.run("")
    assert {:error, :empty} = Check.run(" \n\t")
    assert {:error, :not_hex} = Check.run("<script>alert(1)</script>")
    assert {:error, :not_hex} = Check.run("abc")
    assert {:error, :not_hex} = Check.run(<<0xFF, 0xFE, 0x00, 0x80>>)
    assert {:error, :unknown_format} = Check.run("00000000")
  end

  test "every reason the reader can give has its own sentence" do
    fallback = Check.message(:no_such_reason)

    reasons =
      "lib/bitblocks/chain/beef/reader.ex"
      |> File.read!()
      |> then(&Regex.run(~r/@type reason ::(.*?)\n\n/s, &1, capture: :all_but_first))
      |> hd()
      |> then(&Regex.scan(~r/:([a-z_0-9]+)/, &1, capture: :all_but_first))
      |> List.flatten()

    assert length(reasons) > 20

    for reason <- reasons do
      assert Check.message(String.to_existing_atom(reason)) != fallback, reason
    end
  end

  test "a report keeps a bounded list, the subject first, and counts them all" do
    txs = for tag <- 1..(Check.max_rows() + 25), do: {tx(tag), nil}
    subject = txs |> List.last() |> elem(0) |> Reader.txid()

    assert {:ok, report} = Check.run(Beef.encode([], txs))

    assert report.total == Check.max_rows() + 25
    assert length(report.rows) == Check.max_rows()
    assert report.counts == %{unknown: report.total}
    assert %{txid: ^subject, subject: true} = hd(report.rows)
  end

  test "a report holds no reference to the input" do
    {:ok, report} = Check.run(hex("brc62-example"))

    refute Map.has_key?(report, :transactions)
    refute Map.has_key?(report, :proven)
    refute inspect(report, limit: :infinity, printable_limit: :infinity) =~ hex("brc62-example")
  end

  test "states what it doesn't check" do
    {:ok, report} = Check.run(hex("brc62-example"))

    assert report.claim =~ "Inclusion in a block only"
    assert "double_spends" in report.not_checked
    assert "payment_terms" in report.not_checked
  end
end
