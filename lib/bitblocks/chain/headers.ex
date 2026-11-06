defmodule Bitblocks.Chain.Headers do
  @moduledoc """
  Block headers from the `blocks` table, each rebuilt and checked as it is read.

  Everything here reads by the unique height index and selects the header's
  own columns, never `tx`, which can hold a txid list.

  ## What a header's two flags mean

    * `verified`: the row's fields rebuild an 80-byte header that hashes to the
      row's `hash` and meets the proof of work in its own `bits`
      (`Chain.HeaderVerifier`). Sync stores headers only after that check, but
      the admin block form writes rows without it, so it is made again on every
      read. When it fails, `header` is nil.
    * `canonical`: the row is the block this index holds at its height, and the
      stored block one height up, if any, names it as `prevblockhash`. This is
      the rule `Chain.MerkleProof` applies. The highest block we hold has
      nothing above it yet.

  A caller should rely on a header only when both are true.

  ## What this doesn't say

  The proof-of-work check takes `bits` from the header, and doesn't work out
  what `bits` should be at that height. We trust our node for that, and for
  which fork is the longest; check the headers against a second source for
  anything that can't take that on trust.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, HeaderVerifier}
  alias Bitblocks.Repo

  # blocks.height is a 32-bit column; past this a query parameter won't encode.
  @max_height 2_147_483_647

  @doc "The highest height a query can ask for."
  @spec max_height() :: pos_integer()
  def max_height, do: @max_height

  @doc "The header at `height`, or nil when we hold none."
  @spec at(integer()) :: map() | nil
  def at(height) when is_integer(height), do: heights([height]) |> Map.get(height)

  @doc "The headers we hold at these heights, as `%{height => header}`."
  @spec heights([integer()]) :: %{optional(integer()) => map()}
  def heights(heights) when is_list(heights) do
    wanted = heights |> Enum.filter(&queryable?/1) |> MapSet.new()

    if MapSet.size(wanted) == 0 do
      %{}
    else
      asked =
        wanted
        |> Enum.flat_map(&[&1, &1 + 1])
        |> Enum.uniq()
        |> Enum.filter(&queryable?/1)

      rows = Repo.all(from b in Block, where: b.height in ^asked, select: ^fields())
      present(rows, wanted)
    end
  end

  @doc "The headers held from `from` through `from + count - 1`, in height order."
  @spec range(integer(), pos_integer()) :: [map()]
  def range(from, count) when is_integer(from) and is_integer(count) and count > 0 do
    if queryable?(from) do
      to = min(from + count - 1, @max_height)
      above = min(to + 1, @max_height)

      rows =
        Repo.all(
          from b in Block,
            where: b.height >= ^from and b.height <= ^above,
            order_by: [asc: b.height],
            select: ^fields()
        )

      rows
      |> present(MapSet.new(from..to))
      |> Map.values()
      |> Enum.sort_by(& &1.height)
    else
      []
    end
  end

  @doc """
  Whether the stored block one height above `height` builds on `hash`, or
  nothing is stored there yet.
  """
  @spec child_builds_on?(integer(), String.t()) :: boolean()
  def child_builds_on?(height, hash) do
    child =
      Repo.one(
        from b in Block, where: b.height == ^(height + 1), select: b.prevblockhash, limit: 1
      )

    builds_on?(child, hash)
  end

  defp builds_on?(nil, _hash), do: true
  defp builds_on?(child_prev, hash), do: same_hash?(child_prev, hash)

  defp same_hash?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_hash?(_a, _b), do: false

  defp queryable?(height), do: is_integer(height) and height >= 0 and height <= @max_height

  defp fields do
    [:height, :hash, :merkleroot, :prevblockhash, :version, :time, :bits, :nonce, :num_tx]
  end

  defp present(rows, wanted) do
    by_height = Map.new(rows, &{&1.height, &1})

    for %{height: height} = row <- rows, MapSet.member?(wanted, height), into: %{} do
      child = Map.get(by_height, height + 1)
      {height, header(row, child)}
    end
  end

  defp header(row, child) do
    raw = verified_header(row)

    %{
      height: row.height,
      hash: row.hash,
      merkleroot: row.merkleroot,
      prevblockhash: row.prevblockhash,
      version: row.version,
      time: row.time,
      bits: row.bits,
      nonce: row.nonce,
      num_tx: row.num_tx,
      header: raw && Base.encode16(raw, case: :lower),
      verified: raw != nil,
      canonical: builds_on?(child && child.prevblockhash, row.hash)
    }
  end

  defp verified_header(row) do
    fields = verifier_fields(row)

    with hash when is_binary(hash) <- row.hash,
         :ok <- HeaderVerifier.verify(fields, String.downcase(hash)),
         {:ok, raw} <- HeaderVerifier.serialize(fields) do
      raw
    else
      _ -> nil
    end
  end

  defp verifier_fields(row) do
    fields = %{
      "version" => row.version,
      "merkleroot" => row.merkleroot,
      "time" => row.time,
      "bits" => row.bits,
      "nonce" => row.nonce
    }

    # Genesis has no parent: stored blank, it serializes as all zeros. Any other
    # row left blank then fails to hash to its own hash.
    if row.prevblockhash in [nil, ""],
      do: fields,
      else: Map.put(fields, "previousblockhash", row.prevblockhash)
  end
end
