defmodule Bitblocks.RestoreCheck do
  @moduledoc """
  The numbers that say a restored database holds what its source held
  (docs/RESTORE.md, https://github.com/afomi/bitblocks/issues/55).

  Run it on the source and on the restore with the same `through:` height,
  and compare. Rows at heights up to `complete_through` change only through
  backfills and repairs (`reopen_short_blocks`, a reorg reconcile), so with
  those paused the rows at heights `0..through` match exactly even while the
  source keeps syncing above it.

    * `complete_through` and `tip`, from `Bitblocks.Sync`.
    * `chain.digest`: sha256 over `"<height>:<hash>\\n"` for every block
      `0..through`, in height order. Equal digests mean the same chain.
    * `bounded`: rows per table at heights `0..through`, for `blocks`
      (`height`) and every table with a `block_height` column, per
      #{50_000}-block bucket so a mismatch says where it is. A table with a
      `raw` column (`transactions`) also counts the rows holding `raw` and
      the bytes of it (`octet_length`, read from the TOAST header without
      detoasting), so rows that lost their bytes change the fingerprint.
    * `unbounded`: rows in every other table (`spend_index`, `users`, …),
      exact by default, or the planner's estimates.
    * `headers`: every header `0..through` rebuilt and checked by
      `Bitblocks.Chain.Headers` (proof of work and hash, and the chain links).
    * `sample`: one tx from each of `sample` random blocks, its row's own
      `raw` hashed: each must hash to its txid. A row without `raw` fails as
      `:no_raw_in_row`, unless the row says its bytes moved to the store
      (`raw_in_db` false); only then are they read from the store, and
      counted apart as `from_store`.
    * `fingerprint`: sha256 of `through`, the chain digest and the bounded
      totals, for comparing a restore with a source that keeps changing.
    * `full_fingerprint`: the fingerprint's text plus every unbounded count,
      only with `unbounded: :exact`; for comparing two copies of a quiet
      database, such as the final archive's snapshot restore and its dump
      restore.

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
          bounded: %{optional(String.t()) => map()},
          unbounded: %{optional(String.t()) => non_neg_integer()},
          unbounded_mode: :exact | :estimate,
          headers: map(),
          sample: map(),
          fingerprint: String.t(),
          full_fingerprint: String.t() | nil,
          ok: boolean(),
          failures: [String.t()]
        }

  @doc """
  Reads the numbers. Options:

    * `through:` the height to compare through (this database's
      `complete_through`);
    * `sample:` txs to hash (100);
    * `unbounded:` `:exact` (default) or `:estimate` (the planner's
      `reltuples`, instant on a big table, and no `full_fingerprint`);
    * `statement_timeout_ms:` a cap on each statement (none), set with
      `SET LOCAL`, so a run on a busy source can't hold a scan for hours;
      a statement past it raises and the run stops.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SET TRANSACTION READ ONLY")

          case Keyword.get(opts, :statement_timeout_ms) do
            nil ->
              :ok

            ms when is_integer(ms) and ms > 0 ->
              Repo.query!("SET LOCAL statement_timeout = #{ms}")
          end

          # For tests: runs inside the transaction, to show a write is refused.
          if probe = Keyword.get(opts, :probe), do: probe.()

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
      Map.new(bounded_tables, fn {table, column, raw?} ->
        {table, bounded_count(table, column, raw?, through)}
      end)

    unbounded = Map.new(other_tables, &{&1, unbounded_count(&1, unbounded_mode)})
    chain = chain_digest(through)
    headers = check_headers(through)
    sample = check_sample(through, sample)
    failures = failures(complete_through, through, chain, headers, sample)
    text = fingerprint_text(through, chain, bounded)

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
      fingerprint: sha256(text),
      full_fingerprint:
        if(unbounded_mode == :exact, do: sha256(text <> unbounded_text(unbounded))),
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
      |> Enum.flat_map(fn {table, counts} ->
        ["#{table}=#{counts.total}\n"] ++
          if counts.raw_rows,
            do: [
              "#{table}.raw_rows=#{counts.raw_rows}\n",
              "#{table}.raw_bytes=#{counts.raw_bytes}\n"
            ],
            else: []
      end)

    IO.iodata_to_binary(["through=#{through}\n", "chain=#{chain.digest}\n" | rows])
  end

  @doc "The lines the full fingerprint adds: every unbounded table's count, by name."
  @spec unbounded_text(map()) :: String.t()
  def unbounded_text(unbounded) do
    unbounded
    |> Enum.sort()
    |> Enum.map(fn {table, count} -> "#{table}=#{count}\n" end)
    |> IO.iodata_to_binary()
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

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
  # by (`blocks.height`, or a `block_height` column), with whether they hold
  # `raw`, and the rest.
  defp tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT t.table_name,
             coalesce(bool_or(c.column_name = 'block_height'), false),
             coalesce(bool_or(c.column_name = 'raw'), false)
      FROM information_schema.tables t
      LEFT JOIN information_schema.columns c
        ON c.table_schema = t.table_schema AND c.table_name = t.table_name
      WHERE t.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
      GROUP BY t.table_name
      ORDER BY t.table_name
      """)

    {bounded, other} =
      Enum.reduce(rows, {[], []}, fn
        ["blocks", _, raw?], {bounded, other} ->
          {[{"blocks", "height", raw?} | bounded], other}

        [table, true, raw?], {bounded, other} ->
          {[{table, "block_height", raw?} | bounded], other}

        [table, _, _], {bounded, other} ->
          {bounded, [table | other]}
      end)

    {Enum.reverse(bounded), Enum.reverse(other)}
  end

  # One statement per bucket, so `statement_timeout_ms` caps each range
  # rather than the whole table.
  defp bounded_count(_table, _column, raw?, through) when through < 0,
    do: %{total: 0, raw_rows: raw? && 0, raw_bytes: raw? && 0, buckets: []}

  defp bounded_count(table, column, raw?, through) do
    col = quote_ident(column)

    select =
      if raw?,
        do: "count(*), count(raw), coalesce(sum(octet_length(raw)), 0)::bigint",
        else: "count(*)"

    sql = "SELECT #{select} FROM #{quote_ident(table)} WHERE #{col} >= $1 AND #{col} <= $2"

    buckets =
      for lo <- 0..through//@bucket do
        hi = min(lo + @bucket - 1, through)

        case Repo.query!(sql, [lo, hi], timeout: :infinity).rows do
          [[rows, raw_rows, raw_bytes]] ->
            %{from: lo, rows: rows, raw_rows: raw_rows, raw_bytes: raw_bytes}

          [[rows]] ->
            %{from: lo, rows: rows, raw_rows: nil, raw_bytes: nil}
        end
      end

    %{
      total: sum(buckets, :rows),
      raw_rows: raw? && sum(buckets, :raw_rows),
      raw_bytes: raw? && sum(buckets, :raw_bytes),
      buckets: buckets
    }
  end

  defp sum(buckets, key), do: Enum.reduce(buckets, 0, &(Map.fetch!(&1, key) + &2))

  defp unbounded_count(table, :exact) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM #{quote_ident(table)}", [], timeout: :infinity)

    count
  end

  defp unbounded_count(table, :estimate) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT greatest(reltuples, 0)::bigint FROM pg_class WHERE oid = $1::text::regclass",
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
    do: %{checked: 0, ok: 0, from_store: 0, bad: []}

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
          select: {t.txid, t.raw, t.raw_in_db}
      )
    end)
    |> Enum.reduce(%{checked: 0, ok: 0, from_store: 0, bad: []}, fn row, acc ->
      acc = %{acc | checked: acc.checked + 1}

      case sample_row(row) do
        :ok -> %{acc | ok: acc.ok + 1}
        :ok_from_store -> %{acc | from_store: acc.from_store + 1}
        {:error, txid, reason} -> %{acc | bad: acc.bad ++ [{txid, reason}]}
      end
    end)
  end

  # The row's own bytes, never the store's, unless the row says they moved.
  defp sample_row({txid, raw, _raw_in_db}) when is_binary(raw) and raw != "" do
    case Base.decode16(raw, case: :mixed) do
      {:ok, bytes} -> hashes(txid, bytes, :ok)
      :error -> {:error, txid, :invalid_hex}
    end
  end

  defp sample_row({txid, _raw, false}) do
    case TxStore.raw(txid) do
      {:ok, bytes} -> hashes(txid, bytes, :ok_from_store)
      {:error, reason} -> {:error, txid, {:store, reason}}
    end
  end

  defp sample_row({txid, _raw, _raw_in_db}), do: {:error, txid, :no_raw_in_row}

  defp hashes(txid, bytes, ok) do
    if TxStore.txid(bytes) == String.downcase(txid),
      do: ok,
      else: {:error, txid, :bytes_do_not_hash_to_txid}
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
      sample.bad != [] && "#{length(sample.bad)} sampled tx(s) failed: #{sample_reasons(sample)}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp sample_reasons(sample) do
    sample.bad
    |> Enum.frequencies_by(fn {_txid, reason} -> inspect(reason) end)
    |> Enum.map_join(", ", fn {reason, n} -> "#{n} #{reason}" end)
  end
end
