defmodule Bitblocks.DerivationsDescribeTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Derivations

  test "a recorded error names our first frame and the statement's head" do
    e = %Postgrex.Error{
      postgres: %{
        code: :query_canceled,
        message: "canceling statement due to statement timeout",
        pg_code: "57014",
        severity: "ERROR"
      },
      query: "UPDATE transactions AS t\n  SET tx_types = x\n  WHERE t.id = u.id"
    }

    stack = [
      {Postgrex, :query!, 4, [file: ~c"lib/postgrex.ex", line: 1]},
      {Bitblocks.Derivations, :bounded, 2, [file: ~c"lib/bitblocks/derivations.ex", line: 2]},
      {Bitblocks.Chain.TxPipeline.TxTypesBackfill, :write, 2,
       [file: ~c"lib/bitblocks/chain/tx_pipeline/tx_types_backfill.ex", line: 261]}
    ]

    text = Derivations.describe(e, stack)

    assert text =~ "57014"

    assert text =~
             "at Bitblocks.Chain.TxPipeline.TxTypesBackfill.write/2 (lib/bitblocks/chain/tx_pipeline/tx_types_backfill.ex:261)"

    assert text =~ "in: UPDATE transactions AS t SET tx_types = x WHERE t.id = u.id"
  end

  test "any other error keeps its message" do
    assert Derivations.describe(%RuntimeError{message: "boom"}, []) == "boom"
  end
end
