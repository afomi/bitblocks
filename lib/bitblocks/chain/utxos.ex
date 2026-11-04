defmodule Bitblocks.Chain.Utxos do
  @moduledoc """
  Spent-ness and balances that are exact or say they are unknown (#36).

  ## The rule

  A `spend_index` row is a fact: a stored tx spends that outpoint.
  The absence of a row is only a fact inside a fully synced range.
  The sync loop fills upward from genesis, and `Sync.complete_through/0`
  is the highest H such that every block 0..H is `completed` (merkleroot
  rebuilt, every tx stored). A spend of any output can sit in any later
  block, so "no spend row" means unspent only when every block from the
  output's height through our tip is completed. We read that as
  `complete_through == tip`: the sync never skips a block, so a completed
  run above a gap is short-lived, and one number keeps the contract simple.

  Each output is one of:

    * `:spent`: a spend row names a spending tx, and that tx is in a block
      we store (canonical: heights are unique and reorgs replace the row).
    * `:unspent`: no spend row, the output's tx is in a stored block, and
      `indexed_through_height == tip_height`. Exact as of our tip header.
    * `:unknown`: anything else. No spend row while blocks above
      `indexed_through_height` are not synced yet (a spend may be there);
      a spend row whose spending tx isn't in a stored block (an orphan
      left by a reorg); or an output whose own tx isn't in a stored block.
    * `:unspendable`: OP_RETURN, which no tx can spend (`output_status/1`
      only; it pays no address and no one spends by its script).

  A balance is `:exact` only when every output it counts is `:spent` or
  `:unspent`, so it says `confirmed` only then. Otherwise it is
  `:partial` (some of the chain is indexed from genesis up) or `:unknown`
  (nothing is: no tip, or block 0 isn't complete), and it gives the
  satoshis whose spent-ness is `unknown` instead of a confirmed number.
  Every answer carries `indexed_through_height` and `tip_height`.

  ## Exact satoshis and addresses

  Amounts and scripts come from each tx's raw hex (`Chain.RawTx.flows/1`),
  never from the RPC JSON `value` floats. An output pays an address when
  its script is P2PKH or P2PK (`RawBlock.script_address/1`), the same
  forms `output_addresses` is built from. An output with no address is not
  in any address's balance. A stored tx whose raw hex doesn't decode makes
  the answer `:partial`, since we can't tell which of its outputs count.

  Candidate txs come from the GIN-indexed tag arrays (`output_addresses`,
  `output_script_hashes`); spends from `spend_index` by `(txid, vout)`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{RawBlock, RawTx, Spend, Transaction}
  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.TxPipeline.Steps.Flows
  alias Bitblocks.Repo
  alias Bitblocks.Sync

  @type coverage :: %{
          indexed_through_height: integer(),
          tip_height: integer() | nil,
          complete?: boolean()
        }

  @type output :: %{
          txid: String.t(),
          vout: non_neg_integer(),
          satoshis: non_neg_integer(),
          block_height: integer() | nil,
          status: :spent | :unspent | :unknown,
          spent_by: String.t() | nil,
          spent_by_vin: non_neg_integer() | nil
        }

  @type set :: %{
          status: :exact | :partial | :unknown,
          indexed_through_height: integer(),
          tip_height: integer() | nil,
          outputs: [output()]
        }

  @doc """
  How far absence of a spend can be trusted: `indexed_through_height`
  (`Sync.complete_through/0`), `tip_height` (our highest stored header),
  and `complete?` when the two meet.
  """
  @spec coverage() :: coverage()
  def coverage do
    tip = Sync.tip()
    through = Sync.complete_through(tip)
    %{indexed_through_height: through, tip_height: tip, complete?: tip != nil and through == tip}
  end

  @doc """
  Every output paying `address` in a stored tx, each with its status
  (`:spent`, `:unspent` or `:unknown`), and the set's status.
  """
  @spec for_address(String.t()) :: set()
  def for_address(address) when is_binary(address) do
    from(t in Transaction,
      where: fragment("? @> ARRAY[?]::varchar[]", t.output_addresses, ^address)
    )
    |> collect(fn script -> RawBlock.script_address(script) == address end)
  end

  @doc "As `for_address/1`, for the outputs locked by the script with this Electrum scripthash."
  @spec for_script_hash(String.t()) :: set()
  def for_script_hash(script_hash) when is_binary(script_hash) do
    from(t in Transaction,
      where: fragment("? @> ARRAY[?]::varchar[]", t.output_script_hashes, ^script_hash)
    )
    |> collect(fn script -> electrum_hash(script) == script_hash end)
  end

  @doc """
  The balance of `address` as a map: `status`, `indexed_through_height`,
  `tip_height`, and either `confirmed` (exact) or `unknown` (the satoshis
  whose spent-ness isn't settled), never both.
  """
  @spec balance(String.t()) :: map()
  def balance(address) when is_binary(address) do
    address |> for_address() |> summarize()
  end

  @doc "The outputs of a set with `status`, each as `%{txid, vout, satoshis, block_height}`."
  @spec with_status(set(), atom()) :: [map()]
  def with_status(%{outputs: outputs}, status) do
    for %{status: ^status} = out <- outputs do
      Map.take(out, [:txid, :vout, :satoshis, :block_height])
    end
  end

  @doc "The balance shape of `balance/1`, for any output set."
  @spec summarize(set()) :: map()
  def summarize(%{status: status, outputs: outputs} = set) do
    base = Map.take(set, [:status, :indexed_through_height, :tip_height])

    sum = fn wanted ->
      outputs |> Enum.filter(&(&1.status == wanted)) |> Enum.sum_by(& &1.satoshis)
    end

    case status do
      :exact -> Map.put(base, :confirmed, sum.(:unspent))
      _ -> Map.put(base, :unknown, sum.(:unknown))
    end
  end

  @doc """
  One outpoint from local data: `%{txid, vout, satoshis, script, address,
  block_height, status, spent_by, spent_by_vin}` plus the coverage fields,
  `{:error, :not_found}` when the tx isn't stored or has no such output, or
  `{:error, :undecodable}` when its raw hex doesn't decode.
  """
  @spec outpoint(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def outpoint(txid, vout) when is_binary(txid) and is_integer(vout) do
    with %{} = row <- txs(from(t in Transaction, where: t.txid == ^txid)) |> List.first(),
         {:ok, %{outputs: outputs}} <- RawTx.flows(row.raw),
         {sats, script} <- Enum.at(outputs, vout) do
      coverage = coverage()
      spends = spends([txid])

      status =
        if Flows.unspendable?(script),
          do: {:unspendable, nil, nil},
          else: classify({txid, vout}, row.canonical?, spends, coverage)

      {status, by, vin} = status

      {:ok,
       %{
         txid: txid,
         vout: vout,
         satoshis: sats,
         script: script,
         address: RawBlock.script_address(script),
         block_height: row.block_height,
         status: status,
         spent_by: by,
         spent_by_vin: vin,
         indexed_through_height: coverage.indexed_through_height,
         tip_height: coverage.tip_height
       }}
    else
      nil -> {:error, :not_found}
      {:error, :invalid_tx} -> {:error, :undecodable}
    end
  end

  @doc """
  Each output of a stored tx with its status (`:unspendable` included),
  in vout order, and the coverage it was judged against. nil when the tx
  isn't stored or doesn't decode. Backs `Chain.output_status/1`.
  """
  @spec of_tx(String.t()) :: map() | nil
  def of_tx(txid) when is_binary(txid) do
    with %{} = row <- txs(from(t in Transaction, where: t.txid == ^txid)) |> List.first(),
         {:ok, %{outputs: outputs}} <- RawTx.flows(row.raw) do
      coverage = coverage()
      spends = spends([txid])

      statuses =
        outputs
        |> Enum.with_index()
        |> Enum.map(fn {{sats, script}, vout} ->
          {status, by, vin} =
            if Flows.unspendable?(script),
              do: {:unspendable, nil, nil},
              else: classify({txid, vout}, row.canonical?, spends, coverage)

          %{vout: vout, satoshis: sats, status: status, spent_by: by, spent_by_vin: vin}
        end)

      %{
        txid: txid,
        utxo?: Enum.any?(statuses, &(&1.status == :unspent)),
        outputs: statuses,
        indexed_through_height: coverage.indexed_through_height,
        tip_height: coverage.tip_height
      }
    else
      _ -> nil
    end
  end

  # -- Internals ----------------------------------------------------------------

  defp collect(query, matches?) do
    coverage = coverage()
    rows = txs(query)
    spends = rows |> Enum.map(& &1.txid) |> spends()

    {outputs, undecoded} =
      Enum.reduce(rows, {[], 0}, fn row, {acc, undecoded} ->
        case RawTx.flows(row.raw || "") do
          {:ok, %{outputs: outs}} ->
            found =
              for {{sats, script}, vout} <- Enum.with_index(outs),
                  matches?.(script) do
                {status, by, vin} = classify({row.txid, vout}, row.canonical?, spends, coverage)

                %{
                  txid: row.txid,
                  vout: vout,
                  satoshis: sats,
                  block_height: row.block_height,
                  status: status,
                  spent_by: by,
                  spent_by_vin: vin
                }
              end

            {Enum.reverse(found, acc), undecoded}

          _ ->
            {acc, undecoded + 1}
        end
      end)

    outputs = Enum.sort_by(outputs, &{&1.block_height || -1, &1.txid, &1.vout})

    %{
      status: set_status(coverage, outputs, undecoded),
      indexed_through_height: coverage.indexed_through_height,
      tip_height: coverage.tip_height,
      outputs: outputs
    }
  end

  defp set_status(%{tip_height: nil}, _outputs, _undecoded), do: :unknown
  defp set_status(%{indexed_through_height: h}, _outputs, _undecoded) when h < 0, do: :unknown

  defp set_status(%{complete?: true}, outputs, 0) do
    if Enum.any?(outputs, &(&1.status == :unknown)), do: :partial, else: :exact
  end

  defp set_status(_coverage, _outputs, _undecoded), do: :partial

  # Each candidate tx with whether its block is one we store.
  defp txs(query) do
    Repo.all(
      from(t in query,
        left_join: b in Block,
        on: b.hash == t.block_hash,
        select: %{
          txid: t.txid,
          raw: t.raw,
          block_height: t.block_height,
          canonical?: not is_nil(b.id)
        }
      )
    )
  end

  # {txid, vout} => {spending_txid, vin, spender canonical?}
  defp spends([]), do: %{}

  defp spends(txids) do
    Repo.all(
      from(s in Spend,
        where: s.txid in ^txids,
        left_join: st in Transaction,
        on: st.txid == s.spending_txid,
        left_join: sb in Block,
        on: sb.hash == st.block_hash,
        select: {{s.txid, s.vout}, {s.spending_txid, s.spending_vin, not is_nil(sb.id)}}
      )
    )
    |> Map.new()
  end

  defp classify(_outpoint, false, _spends, _coverage), do: {:unknown, nil, nil}

  defp classify(outpoint, true, spends, coverage) do
    case spends do
      %{^outpoint => {by, vin, true}} -> {:spent, by, vin}
      %{^outpoint => {_by, _vin, false}} -> {:unknown, nil, nil}
      _ when coverage.complete? -> {:unspent, nil, nil}
      _ -> {:unknown, nil, nil}
    end
  end

  defp electrum_hash(script) do
    :crypto.hash(:sha256, script)
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end
end
