defmodule Bitblocks.DB.ApplicationNameTest do
  @moduledoc """
  Connections name their role in `application_name`, so pg_stat_activity
  and Performance Insights split the database load by it: the node role on
  every connection (config/runtime.exs), and `bitblocks-sync` and
  `bitblocks-gin_pending` on their own transactions.

  The sandbox wraps each test in a transaction, so a name set local to a
  transaction inside it is still readable once the call returns.
  """
  use Bitblocks.DataCase, async: true

  alias Bitblocks.Chain.{Block, RawBlock, TxIngest}
  alias Bitblocks.DB.GinPending
  alias Bitblocks.OrdinalFixtures

  defp application_name do
    %{rows: [[name]]} = Repo.query!("SELECT current_setting('application_name')")
    name
  end

  test "a connection carries the node role" do
    assert application_name() == "bitblocks-writer"
  end

  test "GIN cleanup names its transaction" do
    GinPending.run()
    assert application_name() == "bitblocks-gin_pending"
  end

  test "a sync insert names its transaction" do
    out = %BSV.TxOut{satoshis: 1_000, script: %BSV.Script{chunks: [:OP_TRUE]}}
    {txid, hex} = OrdinalFixtures.tx([OrdinalFixtures.funding_outpoint()], [out])

    :ok =
      TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)), %Block{
        hash: "app-name-block",
        height: 5
      })

    assert application_name() == "bitblocks-sync"
  end
end
