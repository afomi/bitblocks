defmodule Bitblocks.Reorgs.ProtocolRewind do
  @moduledoc """
  What a reorg does to the protocol rows derived from a transaction (#52, #53).

  A transaction leaves a replaced block one of two ways, and each protocol
  answers for its own rows in each case, by its own rules:

    * **moved**: mined in another block too. `Reconcile.apply_plan/1` or the
      tx fetch (`TxIngest.existing_txids/2`) has pointed it at that block.
      See `Bitblocks.Tokens`, `Bitblocks.OrderBook` and
      `Bitblocks.OrdinalCollections`, each under "Reorgs".
    * **removed**: no block holds it. Its rows stop counting.

  This module is only the list of those protocols, so the two places a
  transaction can move from share it. There is no shared state: nothing here
  knows what a token or a listing is. Metanet, Bitcom and BAP rows are their
  own pieces of work and aren't rewound.

  Both calls run inside the database transaction that moves or removes the
  transactions, so a failure leaves them to be redone together.
  """

  alias Bitblocks.{OrderBook, OrdinalCollections, Tokens}

  @type counts :: %{
          tokens: %{
            moved: non_neg_integer(),
            removed: non_neg_integer(),
            rechecked: non_neg_integer()
          },
          listings: %{
            moved: non_neg_integer(),
            removed: non_neg_integer(),
            reopened: non_neg_integer()
          },
          collection_items: %{
            moved: non_neg_integer(),
            removed: non_neg_integer(),
            retrace: non_neg_integer()
          }
        }

  @doc "No rows touched."
  @spec none() :: counts()
  def none do
    %{
      tokens: %{moved: 0, removed: 0, rechecked: 0},
      listings: %{moved: 0, removed: 0, reopened: 0},
      collection_items: %{moved: 0, removed: 0, retrace: 0}
    }
  end

  @doc "What `moved/3` and `removed/1` would change, from each protocol. Read-only."
  @spec plan([String.t()], [String.t()]) :: counts()
  def plan(moved, removed) do
    %{
      tokens: Tokens.rewind_plan(moved, removed),
      listings: OrderBook.rewind_plan(moved, removed),
      collection_items: OrdinalCollections.rewind_plan(moved, removed)
    }
  end

  @doc "`txids` now sit in the block `hash` at `height`."
  @spec moved([String.t()], String.t(), integer()) :: counts()
  def moved(txids, hash, height) do
    add(none(), %{
      tokens: %{moved: Tokens.rewind_moved(txids, hash, height)},
      listings: %{moved: OrderBook.rewind_moved(txids, hash, height)},
      collection_items: OrdinalCollections.rewind_moved(txids, height)
    })
  end

  @doc """
  No block holds `txids`. Call this after their transaction rows and spend
  edges have gone: what the protocols recompute reads those tables.
  """
  @spec removed([String.t()]) :: counts()
  def removed(txids) do
    add(none(), %{
      tokens: Tokens.rewind_removed(txids),
      listings: OrderBook.rewind_removed(txids),
      collection_items: OrdinalCollections.rewind_removed(txids)
    })
  end

  @doc "Sums two sets of counts."
  @spec add(counts(), map()) :: counts()
  def add(left, right) do
    Map.merge(left, right, fn _protocol, a, b ->
      Map.merge(a, b, fn _field, x, y -> x + y end)
    end)
  end
end
