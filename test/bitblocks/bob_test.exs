defmodule Bitblocks.BobTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Bob

  # A real mainnet B:// + MAP tx (Twetch, 2019), and BPU's own BOB of it from
  # https://github.com/interplanaria/bpu (README, "an example BPU parsed object").
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @fixtures "test/fixtures/bob"

  setup_all do
    bytes =
      "#{@fixtures}/#{@txid}.hex" |> File.read!() |> String.trim() |> Base.decode16!(case: :mixed)

    expected = "#{@fixtures}/#{@txid}.bpu.json" |> File.read!() |> Jason.decode!()
    {:ok, bob} = Bob.from_bytes(bytes)
    %{bob: bob |> Jason.encode!() |> Jason.decode!(), expected: expected}
  end

  test "matches BPU's BOB of the same tx, cell for cell", %{bob: bob, expected: expected} do
    assert bob["tx"] == %{"h" => @txid}

    # BPU's example predates its `seq`, and has no `h` on a cell; both are extra here.
    drop = fn xputs ->
      Enum.map(xputs, fn xput ->
        xput
        |> Map.delete("seq")
        |> Map.update!("tape", fn tapes ->
          Enum.map(tapes, fn tape ->
            Map.update!(tape, "cell", fn cells -> Enum.map(cells, &Map.delete(&1, "h")) end)
          end)
        end)
      end)
    end

    assert drop.(bob["in"]) == expected["in"]
    assert drop.(bob["out"]) == expected["out"]
  end

  test "an OP_RETURN closes its tape and a pipe stands alone", %{bob: bob} do
    [data | _] = bob["out"]
    tapes = data["tape"]

    assert [%{"ops" => "OP_RETURN", "op" => 106}] = Enum.at(tapes, 0)["cell"]

    assert [%{"s" => "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "h" => "3139" <> _} | _] =
             Enum.at(tapes, 1)["cell"]

    assert [%{"s" => "|", "i" => 0, "ii" => 6}] = Enum.at(tapes, 2)["cell"]
    assert data["e"] == %{"v" => 0, "i" => 0, "a" => "false"}
  end

  test "carries each input's sequence, the lock time, and the block when given" do
    bytes =
      "#{@fixtures}/#{@txid}.hex" |> File.read!() |> String.trim() |> Base.decode16!(case: :mixed)

    blk = %{i: 594_000, h: String.duplicate("0", 64), t: 1_565_131_423}

    assert {:ok, %{in: [%{seq: 0xFFFFFFFF}], lock: 0, blk: ^blk}} =
             Bob.from_bytes(bytes, blk: blk)

    assert {:ok, bob} = Bob.from_bytes(bytes)
    refute Map.has_key?(bob, :blk)
  end

  test "an OP_FALSE OP_RETURN is named as bsv 1.x names it" do
    assert [
             %{
               cell: [
                 %{op: 0, ops: "OP_0", i: 0, ii: 0},
                 %{op: 106, ops: "OP_RETURN", i: 1, ii: 1}
               ]
             },
             %{cell: [%{s: "hi", i: 0, ii: 2}]}
           ] =
             Bob.tapes([:OP_FALSE, :OP_RETURN, "hi"])
  end

  test "bytes that aren't a tx are refused" do
    assert {:error, :invalid_tx} = Bob.from_bytes(<<1, 2, 3>>)
  end
end
