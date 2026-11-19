defmodule Bitblocks.Chain.TxIngestCancelMessageTest do
  @moduledoc """
  The line logged when Postgres cancels a tx's own INSERT (#87): it names
  the stage, the block height, the tx, its size and how long it ran, so the
  digest says which inserts are slow and where.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.TxIngest

  test "names the stage, block, tx, size and time" do
    attrs = %{txid: "ab12", raw: String.duplicate("00", 250), inputs: ["a", "b"], outputs: ["c"]}

    line =
      TxIngest.cancel_message(
        attrs,
        %{height: 389_401},
        "57014",
        50_012,
        "canceling statement due to statement timeout"
      )

    assert line =~ "step=insert_row"
    assert line =~ "block=389401"
    assert line =~ "tx=ab12"
    assert line =~ "code=57014"
    assert line =~ "took=50012ms"
    assert line =~ "inputs=2 outputs=1 size=250"
    assert line =~ "statement timeout"
  end

  test "says unknown when the block or the raw bytes aren't at hand" do
    line = TxIngest.cancel_message(%{txid: "cd34"}, nil, "55P03", 25_000, "lock timeout")

    assert line =~ "block=unknown"
    assert line =~ "size=unknown"
    assert line =~ "inputs=0 outputs=0"
  end
end
