defmodule Bitblocks.Elections.Archive do
  @moduledoc """
  The election archive (`docs/ELECTION_DOGFOOD.md`, "The archive"): a
  directory of static files from which anyone can recount the election with
  no network call, once Bitblocks has spun down.

      archive.json        what each file is: the election, the window, the records in chain order
      count.json          the input given to Count.count/4, and its result
      roll.json           the roll file, its exact bytes on chain
      headers.bin         80-byte block headers, the roll's block to closes_at_height + 6
      txs/<txid>.bin      each record tx's raw bytes
      proofs/<txid>.bump  each confirmed record's BUMP (BRC-74), against a header above
      MANIFEST.sha256     sha256sum lines for every file above, sorted by path

  `archive_sha256` is the sha256 of `MANIFEST.sha256`; the result record
  carries it. The same chain gives byte-identical files: nothing here reads a
  clock, and every JSON file is written with sorted keys.

  An archive is refused until `closes_at_height` is #{Bitblocks.Elections.depth()}
  blocks deep, naming how many blocks remain, and until our index covers
  every block through that height.
  """

  alias Bitblocks.Chain.{Beef, Headers}
  alias Bitblocks.Elections

  @format "bitblocks-election-archive"
  @format_version "0.1.0"
  @manifest "MANIFEST.sha256"
  @spec_url "https://github.com/afomi/bitblocks/blob/develop/docs/ELECTION_DOGFOOD.md"
  @vectors_url "https://bitblocks.app/interop/elections/count/v0.json"
  @recount_url "https://bitblocks.app/elections/recount.py"
  @recount_guide_url "https://bitblocks.app/elections/recount.html"

  @doc """
  The archive's files without writing them: `{:ok, %{election,
  archive_sha256, files: [%{path, bytes, sha256}], count}}`, or the reason it
  can't be built yet. Options as `Elections.gather/2`.
  """
  @spec plan(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(election_outpoint, opts \\ []) do
    with {:ok, gathered} <- Elections.gather(election_outpoint, opts),
         :ok <- deep_enough(gathered),
         :ok <- covered(gathered),
         :ok <- roll_confirmed(gathered),
         {:ok, headers} <- headers(headers_from(gathered), gathered.window.to_height),
         {:ok, counted} <- Elections.count(gathered) do
      files = files(gathered, headers, counted)
      manifest = manifest(files)
      files = files ++ [{@manifest, manifest}]

      {:ok,
       %{
         election: election_outpoint,
         archive_sha256: sha256(manifest),
         close_block_hash: counted.close_block_hash,
         count: counted.count,
         files: Enum.map(files, fn {path, bytes} -> file_entry(path, bytes) end)
       }}
    end
  end

  @doc """
  Writes the archive to `dir` and reads every file back against its sha256.
  `dir` may exist, holding nothing but an earlier copy of this archive's
  files. Returns `plan/2`'s answer with `dir`.
  """
  @spec build(String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(election_outpoint, dir, opts \\ []) do
    with {:ok, plan} <- plan(election_outpoint, opts),
         :ok <- writable(dir, plan.files),
         :ok <- write(dir, plan.files) do
      {:ok, Map.put(plan, :dir, dir)}
    end
  end

  # -- Refusals ---------------------------------------------------------------

  defp deep_enough(%{window: window, coverage: %{tip_height: tip}}) do
    needed = window.to_height

    if is_integer(tip) and tip >= needed do
      :ok
    else
      {:error,
       {:too_shallow,
        %{
          closes_at_height: window.closes_at_height,
          needed_height: needed,
          tip_height: tip,
          blocks_remaining: needed - (tip || 0)
        }}}
    end
  end

  defp covered(%{window: window, coverage: coverage}) do
    if coverage.complete,
      do: :ok,
      else:
        {:error,
         {:not_covered,
          %{needed_height: window.to_height, covered_through: coverage.covered_through}}}
  end

  defp roll_confirmed(%{roll: %{height: h}}) when is_integer(h), do: :ok
  defp roll_confirmed(_gathered), do: {:error, :roll_unconfirmed}

  # From the roll's block (at or below the election's), so every record's
  # BUMP has its header in the file.
  defp headers_from(gathered), do: min(gathered.roll.height, gathered.window.from_height)

  defp headers(from, to) do
    held = Headers.range(from, to - from + 1)
    by_height = Map.new(held, &{&1.height, &1})

    Enum.reduce_while(from..to//1, {:ok, []}, fn height, {:ok, acc} ->
      case Map.get(by_height, height) do
        %{verified: true, canonical: true, header: hex} = header ->
          {:cont, {:ok, [Map.put(header, :raw, Base.decode16!(hex, case: :lower)) | acc]}}

        _ ->
          {:halt, {:error, {:header_unavailable, height}}}
      end
    end)
    |> case do
      {:ok, headers} -> chained(Enum.reverse(headers))
      error -> error
    end
  end

  # Each header names the one below it, so the file is one chain.
  defp chained(headers) do
    headers
    |> Enum.zip(Enum.drop(headers, 1))
    |> Enum.find(fn {below, above} ->
      String.downcase(above.prevblockhash || "") != String.downcase(below.hash)
    end)
    |> case do
      nil -> {:ok, headers}
      {_below, above} -> {:error, {:header_chain_broken, above.height}}
    end
  end

  # -- Files ------------------------------------------------------------------

  defp files(gathered, headers, counted) do
    records = [
      record_entry(:election, gathered.election_record),
      record_entry(:roll, gathered.roll)
    ]

    records = records ++ Enum.map(gathered.ballots, &record_entry(:ballot, &1))

    all = [gathered.election_record, gathered.roll | gathered.ballots]

    txs =
      all
      |> Enum.uniq_by(& &1.txid)
      |> Enum.map(&{"txs/#{&1.txid}.bin", &1.bytes})

    proofs =
      all
      |> Enum.filter(& &1.proof)
      |> Enum.uniq_by(& &1.txid)
      |> Enum.map(
        &{"proofs/#{&1.txid}.bump", &1.proof |> Beef.from_proof() |> Beef.encode_bump()}
      )

    window = gathered.window
    inputs = Elections.inputs(gathered)

    index = %{
      format: @format,
      format_version: @format_version,
      status: "draft",
      spec: @spec_url,
      vectors: @vectors_url,
      recount: %{tool: @recount_url, guide: @recount_guide_url},
      election: gathered.election,
      app: gathered.app,
      administrator: gathered.administrator,
      roll: %{
        outpoint: gathered.roll.outpoint,
        sha256: gathered.roll.record.fields["sha256"],
        file: "roll.json"
      },
      window: %{
        from_height: window.from_height,
        opens_at_height: window.opens_at_height,
        closes_at_height: window.closes_at_height,
        to_height: window.to_height
      },
      close_block_hash: counted.close_block_hash,
      headers: %{
        file: "headers.bin",
        from_height: headers |> List.first() |> Map.fetch!(:height),
        to_height: window.to_height,
        count: length(headers),
        bytes_each: 80
      },
      records: records,
      count: %{file: "count.json", counted: counted.count.counted, winners: counted.count.winners},
      manifest: @manifest,
      how_to_check: [
        "sha256sum -c MANIFEST.sha256 checks every file; the sha256 of MANIFEST.sha256 itself is the archive_sha256 in the result record.",
        "headers.bin holds one 80-byte header per height from headers.from_height to headers.to_height: each must hash (sha256d) below its own target, and name the one before it as its parent.",
        "Each txs/<txid>.bin must hash (sha256d, reversed) to its txid, and each proofs/<txid>.bump (BRC-74) must climb from that txid to the merkle root of the header at the BUMP's height; the txid's leaf offset is its position.",
        "Each record is read from its tx's output vout: a MAP SET with an AIP signature over every MAP field (and the roll's B:// file), as the spec says.",
        "roll.json must hash to roll.sha256, the election's roll_sha256.",
        "count.json holds the input given to the counting rule and its result: rebuild the input from the txs, run the rule (its vectors are at the vectors URL), and compare.",
        "recount.tool does every step above offline, from these files alone: python3 recount.py <this folder> --archive-sha256 <archive_sha256>."
      ]
    }

    count = %{input: inputs, result: counted.count}

    [
      {"archive.json", json(index)},
      {"count.json", json(count)},
      {"roll.json", gathered.roll.record.fields["content"]},
      {"headers.bin", headers |> Enum.map(& &1.raw) |> IO.iodata_to_binary()}
    ] ++ Enum.sort(txs) ++ Enum.sort(proofs)
  end

  defp record_entry(kind, record) do
    %{
      kind: kind,
      txid: record.txid,
      vout: record.vout,
      height: record.height,
      position: record.position,
      block_hash: record.height && record.block_hash,
      signer: record.signer,
      tx: "txs/#{record.txid}.bin",
      proof: record.proof && "proofs/#{record.txid}.bump"
    }
  end

  defp manifest(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, bytes} -> [sha256(bytes), "  ", path, "\n"] end)
    |> IO.iodata_to_binary()
  end

  defp file_entry(path, bytes), do: %{path: path, bytes: bytes, sha256: sha256(bytes)}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  JSON as the archive writes it: keys sorted at every level, two-space
  indent, a closing newline; atoms other than true, false and nil as strings.
  """
  @spec json(term()) :: binary()
  def json(term), do: Jason.encode!(ordered(term), pretty: true) <> "\n"

  defp ordered(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> ordered()

  defp ordered(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), ordered(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)

  defp ordered(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp ordered(other), do: other

  # -- Writing ----------------------------------------------------------------

  defp writable(dir, files) do
    ours = MapSet.new(files, & &1.path)

    case existing(dir) do
      [] ->
        :ok

      present ->
        case Enum.reject(present, &MapSet.member?(ours, &1)) do
          [] -> :ok
          others -> {:error, {:dir_not_empty, dir, Enum.take(others, 5)}}
        end
    end
  end

  defp existing(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
    else
      []
    end
  end

  defp write(dir, files) do
    Enum.reduce_while(files, :ok, fn %{path: path, bytes: bytes, sha256: expected}, :ok ->
      full = Path.join(dir, path)

      with :ok <- File.mkdir_p(Path.dirname(full)),
           :ok <- File.write(full, bytes),
           {:ok, read} <- File.read(full),
           true <- sha256(read) == expected do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:write_mismatch, path}}}
        {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
      end
    end)
  end
end
