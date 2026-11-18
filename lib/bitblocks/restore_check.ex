defmodule Bitblocks.RestoreCheck do
  @moduledoc """
  The numbers that say a restored database holds what its source held
  (docs/RESTORE.md, https://github.com/afomi/bitblocks/issues/55).

  Run it on the source and on the restore with the same `through:` height,
  and compare. Below `complete_through` the chain doesn't change, so rows at
  heights `0..through` match exactly even while the source keeps syncing
  above it.

    * `complete_through` and `tip`, from `Bitblocks.Sync`.
    * `chain.digest`: sha256 over `"<height>:<hash>\\n"` for every block
      `0..through`, in height order. Equal digests mean the same chain.
    * `bounded`: rows per table at heights `0..through`, for `blocks`
      (`height`) and every table with a `block_height` column, with the
      count per #{50_000}-block bucket so a mismatch says where it is.
    * `unbounded`: rows in every other table, exact by default; these match
      the source only for a snapshot of a quiet database.
    * `headers`: every header `0..through` rebuilt and checked by
      `Bitblocks.Chain.Headers` (proof of work and hash, and the chain links).
    * `sample`: one tx from each of `sample` random blocks, its bytes read
      through `TxStore.raw/1` (the row, else the store) and hashed: each must
      hash to its txid.
    * `fingerprint`: sha256 of `through`, the chain digest and the bounded
      totals, so source and restore compare on one line.

  Read-only: everything runs in one `READ ONLY` transaction, so Postgres
  refuses any write. Bytes read from the store are only read.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Headers, Transaction}
  alias Bitblocks.{Repo, Sync, TxStore}

  @bucket 50_000
  @digest_batch 10_000
  @header_batch 2_000
  @bad_limit 10

  @type result :: %{
          database: map(),
          tip: integer() | nil,
          complete_through: integer(),
          through: integer(),
          chain: %{digest: String.t(), blocks: non_neg_integer()},
          bounded: %{optional(String.t()) => %{total: non_neg_integer(), buckets: list()}},
          unbounded: %{optional(String.t()) => non_neg_integer()},
          unbounded_mode: :exact | :estimate,
          headers: map(),
          sample: map(),
          fingerprint: String.t(),
          ok: boolean(),
          failures: [String.t()]
        }

  @doc """
  Reads the numbers. Options: `through:` (default this database's
  `complete_through`), `sample:` txs to hash (100), `unbounded:` `:exact`
  (default) or `:estimate` (the planner's `reltuples`, instant on a big
  table).
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SET TRANSACTION READ ONLY")
          read(opts)
        end,
        timeout: :infinity
      )

    result
  end

  defp read(opts) do
    tip = Sync.tip()
    complete_through = Sync.complete_through(tip)
    through = Keyword.get(opts, :through, complete_through)
    sample = Keyword.get(opts, :sample, 100)
    unbounded_mode = Keyword.get(opts, :unbounded, :exact)

    {bounded_tables, other_tables} = tables()

    bounded =
      Map.new(bounded_tables, fn {table, column} ->
        {table, bounded_count(table, column, through)}
      end)

    unbounded = Map.new(other_tables, &{&1, unbounded_count(&1, unbounded_mode)})
    chain = chain_digest(through)
    headers = check_headers(through)
    sample = check_sample(through, sample)
    failures = failures(complete_through, through, chain, headers, sample)

    %{
      database: database(),
      tip: tip,
      complete_through: complete_through,
      through: through,
      chain: chain,
      bounded: bounded,
      unbounded: unbounded,
      unbounded_mode: unbounded_mode,
      headers: headers,
      sample: sample,
      fingerprint: fingerprint(through, chain, bounded),
      ok: failures == [],
      failures: failures
    }
  end

  @doc "The text the fingerprint hashes: one `key=value` line each, in a fixed order."
  @spec fingerprint_text(integer(), map(), map()) :: String.t()
  def fingerprint_text(through, chain, bounded) do
    rows =
      bounded
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {table, %{total: total}} -> "#{table}=#{total}\n" end)

    IO.iodata_to_binary(["through=#{through}\n", "chain=#{chain.digest}\n" | rows])
  end

  defp fingerprint(through, chain, bounded) do
    :crypto.hash(:sha256, fingerprint_text(through, chain, bounded))
    |> Base.encode16(case: :lower)
  end

  defp database do
    %{rows: [[name, host, version]]} =
      Repo.query!(
        "SELECT current_database(), host(inet_server_addr()), current_setting('server_version')"
      )

    %{name: name, host: host || configured_host(), server_version: version}
  end

  defp configured_host do
    config = Repo.config()

    cond do
      config[:hostname] -> config[:hostname]
      config[:url] -> URI.parse(config[:url]).host
      true -> nil
    end
  end

  # Every base table in the schema, split into those with a height to bound
  # by (`blocks.height`, or a `block_height` column) and the rest.
  defp tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT t.table_name,
             bool_or(c.column_name = 'block_height') AS has_block_height
      FROM information_schema.tables t
      LEFT JOIN information_schema.columns c
        ON c.table_schema = t.table_schema AND c.table_name = t.table_name
      WHERE t.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
      GROUP BY t.table_name
      ORDER BY t.table_name
      """)

    Enum.reduce(rows, {[], []}, fn
      ["blocks", _], {bounded, other} -> {[{"blocks", "height"} | bounded], other}
      [table, true], {bounded, other} -> {[{table, "block_height"} | bounded], other}
      [table, _], {bounded, other} -> {bounded, [table | other]}
    end)
    |> then(fn {bounded, other} -> {Enum.reverse(bounded), Enum.reverse(other)} end)
  end

  defp bounded_count(_table, _column, through) when through < 0, do: %{total: 0, buckets: []}

  defp bounded_count(table, column, through) do
    col = quote_ident(column)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT #{col} / #{@bucket} AS bucket, count(*)
        FROM #{quote_ident(table)}
        WHERE #{col} >= 0 AND #{col} <= $1
        GROUP BY 1 ORDER BY 1
        """,
        [through],
        timeout: :infinity
      )

    buckets = Enum.map(rows, fn [bucket, count] -> {bucket * @bucket, count} end)
    %{total: Enum.reduce(buckets, 0, fn {_, n}, acc -> acc + n end), buckets: buckets}
  end

  defp unbounded_count(table, :exact) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM #{quote_ident(table)}", [], timeout: :infinity)

    count
  end

  defp unbounded_count(table, :estimate) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT greatest(reltuples, 0)::bigint FROM pg_class WHERE oid = $1::regclass",
        [quote_ident(table)]
      )

    count
  end

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp chain_digest(through) do
    {ctx, blocks} =
      if through < 0 do
        {:crypto.hash_init(:sha256), 0}
      else
        0..through//@digest_batch
        |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn lo, {ctx, n} ->
          hi = min(lo + @digest_batch - 1, through)

          rows =
            Repo.all(
              from b in Block,
                where: b.height >= ^lo and b.height <= ^hi,
                order_by: [asc: b.height],
                select: {b.height, b.hash}
            )

          ctx =
            Enum.reduce(rows, ctx, fn {height, hash}, ctx ->
              :crypto.hash_update(ctx, "#{height}:#{String.downcase(hash || "")}\n")
            end)

          {ctx, n + length(rows)}
        end)
      end

    %{digest: ctx |> :crypto.hash_final() |> Base.encode16(case: :lower), blocks: blocks}
  end

  defp check_headers(through) do
    empty = %{checked: 0, verified: 0, canonical: 0, missing: 0, bad: []}

    if through < 0 do
      empty
    else
      0..through//@header_batch
      |> Enum.reduce(empty, fn lo, acc ->
        count = min(@header_batch, through - lo + 1)
        headers = Headers.range(lo, count)
        verified = Enum.count(headers, & &1.verified)
        canonical = Enum.count(headers, & &1.canonical)

        bad =
          for h <- headers, not (h.verified and h.canonical), do: h.height

        %{
          acc
          | checked: acc.checked + length(headers),
            verified: acc.verified + verified,
            canonical: acc.canonical + canonical,
            missing: acc.missing + (count - length(headers)),
            bad: Enum.take(acc.bad ++ bad, @bad_limit)
        }
      end)
    end
  end

  defp check_sample(through, n) when through < 0 or n <= 0,
    do: %{checked: 0, ok: 0, bad: []}

  defp check_sample(through, n) do
    0..through
    |> Enum.take_random(n)
    |> Enum.sort()
    |> Enum.flat_map(fn height ->
      Repo.all(
        from t in Transaction,
          where: t.block_height == ^height,
          order_by: [asc: t.txid],
          limit: 1,
          select: t.txid
      )
    end)
    |> Enum.reduce(%{checked: 0, ok: 0, bad: []}, fn txid, acc ->
      case hashes_to_txid(txid) do
        :ok -> %{acc | checked: acc.checked + 1, ok: acc.ok + 1}
        {:error, reason} -> %{acc | checked: acc.checked + 1, bad: acc.bad ++ [{txid, reason}]}
      end
    end)
  end

  defp hashes_to_txid(txid) do
    case TxStore.raw(txid) do
      {:ok, bytes} ->
        if TxStore.txid(bytes) == String.downcase(txid),
          do: :ok,
          else: {:error, :bytes_do_not_hash_to_txid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp failures(complete_through, through, chain, headers, sample) do
    [
      complete_through < 0 && "block 0 is not complete",
      through > complete_through &&
        "compared through #{through}, above this database's complete_through #{complete_through}",
      (through >= 0 and chain.blocks != through + 1) &&
        "#{chain.blocks} blocks at heights 0..#{through}, expected #{through + 1}",
      headers.missing > 0 && "#{headers.missing} header(s) missing",
      headers.checked > headers.verified &&
        "#{headers.checked - headers.verified} header(s) fail verification",
      headers.checked > headers.canonical &&
        "#{headers.checked - headers.canonical} header(s) not canonical",
      sample.bad != [] && "#{length(sample.bad)} sampled tx(s) don't hash to their txid"
    ]
    |> Enum.filter(&is_binary/1)
  end
end
