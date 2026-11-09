defmodule Bitblocks.Chain.AddressHistory do
  @moduledoc """
  Every confirmed tx that touched an address, newest first, with the net
  sats for that address, and whether the list is complete (#80).

  ## Where the rows come from

  Our index answers through `Sync.complete_through/0`, where every block is
  stored: the txs paying the address (`output_addresses`) and the txs
  spending those outputs (`spend_index`), each in a block we store.
  WhatsOnChain answers above it (`Bitblocks.Woc.AddressHistory`: bounded,
  cached, an error past its bound, never a silent partial list), so no
  block is read twice or skipped. When our index reaches our tip,
  WhatsOnChain isn't asked. Each row says its `source`, `local` or
  `whatsonchain`.

  ## Status

  The `Bitblocks.Chain.Utxos` rule, applied to the list:

    * `:exact` — every block from genesis through our tip is covered: by
      our index alone, or by our index plus WhatsOnChain reaching at least
      our tip.
    * `:partial` — some of the chain is covered and some isn't:
      WhatsOnChain unavailable or short of our tip, or a stored tx paying
      the address doesn't decode, so its spends can't be followed.
    * `:unknown` — nothing is: no tip, or block 0 isn't complete and
      WhatsOnChain can't answer.

  ## Net sats

  Outputs paying the address minus the outputs of the address that the
  tx's inputs spend, read from raw bytes (exact integers). An input spends
  the address when its previous output pays it; when that output's tx
  isn't stored or fetched, the input is the address's only if its unlock
  ends with the address's public key (a P2PKH unlock), and then its value
  is unknown, so `net_sats` is nil with the reason `input_value_unknown`.
  An unlock that can't be read counts as someone else's, as in
  `Bitblocks.Support.Received`. A tx whose bytes don't decode, or aren't
  to hand, is nil with `undecodable`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawBlock, RawTx, Spend, Transaction, Utxos}
  alias Bitblocks.Repo
  alias Bitblocks.Woc.AddressHistory, as: WocHistory

  @default_limit 50
  @max_limit 200

  @type row :: %{
          txid: String.t(),
          height: non_neg_integer(),
          net_sats: integer() | nil,
          net_sats_reason: String.t() | nil,
          source: String.t()
        }

  @doc "The page size when none is asked for, and the most one page holds."
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  One page of `address`'s history, newest first by `(height, txid)`.

  Options: `:cursor`, `{height, txid}` from `Chain.decode_tx_cursor/1`
  (rows strictly after it), and `:limit` (default 50, at most 200).

  Returns `%{rows, status, indexed_through_height, tip_height,
  next_cursor, sources}`. `next_cursor` is `"<height>:<txid>"` or nil on
  the last page. `sources` names each source with the heights it covers;
  WhatsOnChain's also has `status` (`ok` or `unavailable`, then with a
  `reason`, and its rows are left out).
  """
  @spec page(String.t(), keyword()) :: map()
  def page(address, opts \\ []) when is_binary(address) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)
    coverage = Utxos.coverage()
    through = coverage.indexed_through_height

    {local, undecoded} = local_rows(address, through)
    woc = if coverage.complete?, do: :skipped, else: WocHistory.above(address, through)

    woc_txs =
      case woc do
        {:ok, %{txs: txs}} -> txs
        _ -> []
      end

    local_txids = MapSet.new(local, & &1.txid)

    remote =
      for %{txid: txid, height: height} <- woc_txs,
          not MapSet.member?(local_txids, txid),
          do: %{txid: txid, height: height, source: "whatsonchain"}

    sorted =
      (local ++ remote)
      |> Enum.sort_by(&{&1.height, &1.txid}, :desc)
      |> after_cursor(Keyword.get(opts, :cursor))

    {page, more?} =
      case Enum.split(sorted, limit) do
        {page, []} -> {page, false}
        {page, _rest} -> {page, true}
      end

    woc_hex = Map.new(woc_txs, &{&1.txid, &1.tx["hex"]})

    %{
      rows: with_net_sats(page, address, woc_hex),
      status: status(coverage, woc, undecoded),
      indexed_through_height: through,
      tip_height: coverage.tip_height,
      next_cursor: if(more?, do: cursor_of(List.last(page))),
      sources: sources(through, woc)
    }
  end

  @doc "The `meta.sources` entry for our own index, which covers genesis through `through`."
  def index_source(through), do: %{source: "index", from_height: 0, through_height: through}

  # -- Local rows -------------------------------------------------------------

  # The txs paying the address, and the txs spending those outputs, in
  # blocks we store through `through`. Returns the rows and how many paying
  # txs didn't decode (their spends can't be followed).
  defp local_rows(_address, through) when through < 0, do: {[], 0}

  defp local_rows(address, through) do
    receipts =
      Repo.all(
        from(t in Transaction,
          join: b in Block,
          on: b.hash == t.block_hash,
          where:
            fragment("? @> ARRAY[?]::varchar[]", t.output_addresses, ^address) and
              b.height <= ^through,
          select: {t.txid, b.height, t.raw}
        )
      )

    {mine, undecoded} =
      Enum.reduce(receipts, {MapSet.new(), 0}, fn {txid, _height, raw}, {mine, undecoded} ->
        case RawTx.flows(raw || "") do
          {:ok, %{outputs: outputs}} ->
            vouts =
              for {{_sats, script}, vout} <- Enum.with_index(outputs),
                  RawBlock.script_address(script) == address,
                  do: {txid, vout}

            {Enum.into(vouts, mine), undecoded}

          _ ->
            {mine, undecoded + 1}
        end
      end)

    receipt_txids = Enum.map(receipts, &elem(&1, 0))

    spender_txids =
      if receipt_txids == [] do
        []
      else
        Repo.all(
          from(s in Spend,
            where: s.txid in ^receipt_txids,
            select: {s.txid, s.vout, s.spending_txid}
          )
        )
        |> Enum.filter(fn {txid, vout, _by} -> MapSet.member?(mine, {txid, vout}) end)
        |> Enum.map(&elem(&1, 2))
        |> Enum.uniq()
      end

    spenders =
      if spender_txids == [] do
        []
      else
        Repo.all(
          from(t in Transaction,
            join: b in Block,
            on: b.hash == t.block_hash,
            where: t.txid in ^spender_txids and b.height <= ^through,
            select: {t.txid, b.height}
          )
        )
      end

    rows =
      (Enum.map(receipts, fn {txid, height, _raw} -> {txid, height} end) ++ spenders)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {txid, height} -> %{txid: txid, height: height, source: "local"} end)

    {rows, undecoded}
  end

  # -- Paging -----------------------------------------------------------------

  defp after_cursor(rows, nil), do: rows

  defp after_cursor(rows, {height, txid}),
    do: Enum.filter(rows, &({&1.height, &1.txid} < {height, txid}))

  defp cursor_of(%{height: height, txid: txid}), do: "#{height}:#{txid}"

  # -- Net sats ---------------------------------------------------------------

  defp with_net_sats([], _address, _woc_hex), do: []

  defp with_net_sats(rows, address, woc_hex) do
    pkh =
      case BSV.Address.from_string(address) do
        {:ok, %{pubkey_hash: pkh}} -> pkh
        _ -> nil
      end

    local_txids = for %{source: "local", txid: txid} <- rows, do: txid
    hex = Map.merge(woc_hex, stored_raw(local_txids))

    flows = Map.new(rows, &{&1.txid, decode(hex[&1.txid])})

    prev_txids =
      for {_txid, {:ok, %{inputs: inputs}}} <- flows,
          {prev, _vout} <- inputs,
          not Map.has_key?(hex, prev),
          uniq: true,
          do: prev

    prevs =
      hex
      |> Map.merge(stored_raw(prev_txids))
      |> Map.new(fn {txid, h} -> {txid, decode(h)} end)

    Enum.map(rows, fn row ->
      {net, reason} = net_sats(flows[row.txid], hex[row.txid], address, pkh, prevs)

      %{
        txid: row.txid,
        height: row.height,
        net_sats: net,
        net_sats_reason: reason,
        source: row.source
      }
    end)
  end

  defp net_sats({:ok, %{inputs: inputs, outputs: outputs}}, hex, address, pkh, prevs) do
    received =
      for {sats, script} <- outputs,
          RawBlock.script_address(script) == address,
          reduce: 0,
          do: (sum -> sum + sats)

    inputs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn
      {:coinbase, _vin}, acc ->
        {:cont, acc}

      {{prev, vout}, vin}, {:ok, spent} ->
        case prev_output(prevs[prev], vout) do
          {sats, script} ->
            if RawBlock.script_address(script) == address,
              do: {:cont, {:ok, spent + sats}},
              else: {:cont, {:ok, spent}}

          nil ->
            if unlocks_with?(hex, vin, pkh),
              do: {:halt, :unknown},
              else: {:cont, {:ok, spent}}
        end
    end)
    |> case do
      {:ok, spent} -> {received - spent, nil}
      :unknown -> {nil, "input_value_unknown"}
    end
  end

  defp net_sats(_undecoded, _hex, _address, _pkh, _prevs), do: {nil, "undecodable"}

  defp prev_output({:ok, %{outputs: outputs}}, vout), do: Enum.at(outputs, vout)
  defp prev_output(_missing, _vout), do: nil

  # A P2PKH unlock ends with a push of the spender's public key.
  defp unlocks_with?(_hex, _vin, nil), do: false

  defp unlocks_with?(hex, vin, pkh) do
    with {:ok, %BSV.Tx{inputs: inputs}} <- RawTx.parse(hex),
         %BSV.TxIn{script: %BSV.Script{chunks: chunks}} <- Enum.at(inputs, vin),
         key when is_binary(key) and byte_size(key) in [33, 65] <- List.last(chunks) do
      BSV.Hash.sha256_ripemd160(key) == pkh
    else
      _ -> false
    end
  end

  defp decode(hex) when is_binary(hex), do: RawTx.flows(hex)
  defp decode(_missing), do: {:error, :invalid_tx}

  defp stored_raw([]), do: %{}

  defp stored_raw(txids) do
    Repo.all(
      from(t in Transaction,
        where: t.txid in ^txids and not is_nil(t.raw) and t.raw != "",
        select: {t.txid, t.raw}
      )
    )
    |> Map.new()
  end

  # -- Coverage ---------------------------------------------------------------

  defp status(%{tip_height: nil}, _woc, _undecoded), do: :unknown
  defp status(%{complete?: true}, _woc, 0), do: :exact

  defp status(%{tip_height: tip}, {:ok, %{through_height: woc_through}}, 0)
       when is_integer(woc_through) and woc_through >= tip,
       do: :exact

  defp status(%{indexed_through_height: through}, {:error, _}, _undecoded) when through < 0,
    do: :unknown

  defp status(_coverage, _woc, _undecoded), do: :partial

  defp sources(through, :skipped), do: [index_source(through)]

  defp sources(through, {:ok, %{through_height: woc_through}}),
    do: [index_source(through), woc_source(through, woc_through, "ok")]

  defp sources(through, {:error, reason}) do
    [
      index_source(through),
      through |> woc_source(nil, "unavailable") |> Map.put(:reason, reason_text(reason))
    ]
  end

  defp woc_source(through, woc_through, status) do
    %{
      source: "whatsonchain",
      from_height: through + 1,
      through_height: woc_through,
      status: status
    }
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({:http_status, status, _body}), do: "http_status_#{status}"
  defp reason_text(_reason), do: "error"
end
