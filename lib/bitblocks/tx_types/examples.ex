defmodule Bitblocks.TxTypes.Examples do
  @moduledoc """
  Real transactions for a transaction type, read from indexes we already keep.

  Never a scan of `transactions` (~10M rows in prod). Each source is one
  indexed, limited query; a count is given only where it is cheap:

    * `"tokens"`: the token index (`protocol_instances` under the BSV20
      protocol). Latest operations of a standard, and a count of its deploys.
    * `"collections"`: `collection_items` for the named collections. Latest
      mints, and a count of items.
    * `"template"`: `transactions.output_template_hashes` (GIN) for one script
      shape, the same column `Chain.history_for_template_hash/1` reads. A shape
      with an aliased opcode (OP_1/OP_TRUE and two others) lists every hash it
      may have been stamped with (`TxTypes.template_hash_variants/1`), and the
      query matches any of them (`&&`, also GIN). No count.
    * `"protocol"`: `transactions.protocols` (GIN) for the protocol detector's
      tags. No count.
    * `"none"`: no cheap source yet; the page says examples are coming.

  Query plans for each source are in afomi/bitblocks#49.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.ProtocolRegistry.Instance
  alias Bitblocks.Repo

  @limit 5
  # A slow plan should fail fast, not hold a page open.
  @timeout 5_000

  @type example :: %{txid: String.t(), block_height: integer() | nil, note: String.t() | nil}

  @type result :: %{
          status: :ok | :coming | :unavailable,
          source: String.t(),
          count: non_neg_integer() | nil,
          count_label: String.t() | nil,
          items: [example()]
        }

  @doc "How many examples a page shows."
  def limit, do: @limit

  @doc """
  The examples for `type`: its latest few transactions from its source index,
  and a count where one is cheap.

  `status` is `:ok` (items may still be empty), `:coming` (no cheap source yet)
  or `:unavailable` (the query failed; it is logged).
  """
  @spec for_type(map(), keyword()) :: result()
  def for_type(type, opts \\ []) do
    limit = Keyword.get(opts, :limit, @limit)
    examples = Map.get(type, :examples, %{kind: "none"})

    try do
      fetch(examples, limit)
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        Logger.warning("tx type #{type.id}: examples query failed: #{Exception.message(error)}")

        %{
          status: :unavailable,
          source: source(examples),
          count: nil,
          count_label: nil,
          items: []
        }
    end
  end

  @doc "A sentence naming where a type's examples come from."
  @spec source(map()) :: String.t()
  def source(%{kind: "tokens", standard: standard}),
    do: "From our token index: the latest #{String.upcase(standard)} operations."

  def source(%{kind: "collections"}),
    do: "From the NFT collections we index: the latest mints."

  def source(%{kind: "template", template_hashes: [hash | _]} = examples) do
    shape = if examples[:shape], do: " (#{examples.shape})", else: ""

    "Transactions with an output of exactly this script shape#{shape}, by template hash #{String.slice(hash, 0, 12)}…"
  end

  def source(%{kind: "protocol", protocols: protocols}),
    do: "Transactions our protocol detector tagged #{Enum.join(protocols, " and ")}."

  def source(%{kind: "none"} = examples),
    do: Map.get(examples, :reason, "There is no index for this type yet.")

  defp fetch(%{kind: "tokens", standard: standard} = examples, limit) do
    case ProtocolRegistry.get_protocol_by_name("BSV20") do
      nil ->
        ok(examples, [], nil, nil)

      %{id: protocol_id} ->
        items =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id,
            where: fragment("?->>'standard' = ?", i.parsed_data, ^standard),
            order_by: [desc: i.id],
            limit: ^limit,
            select: %{
              txid: i.txid,
              block_height: i.block_height,
              op: fragment("?->>'op'", i.parsed_data),
              name:
                fragment(
                  "coalesce(?->>'tick', ?->>'sym')",
                  i.parsed_data,
                  i.parsed_data
                ),
              amt: fragment("?->>'amt'", i.parsed_data)
            }
          )
          |> Repo.all(timeout: @timeout)
          |> Enum.map(&token_example/1)

        {count, label} = token_count(protocol_id, standard)
        ok(examples, items, count, label)
    end
  end

  defp fetch(%{kind: "collections", collections: slugs} = examples, limit) do
    known = OrdinalCollections.known()
    ids = slugs |> Enum.map(&Map.get(known, &1)) |> Enum.reject(&is_nil/1)

    items =
      from(i in Item,
        where: i.collection_id in ^ids,
        where: not is_nil(i.mint_height),
        order_by: [desc: i.mint_height, desc: i.id],
        limit: ^limit,
        select: %{txid: i.mint_txid, block_height: i.mint_height, note: i.name}
      )
      |> Repo.all(timeout: @timeout)

    count =
      from(i in Item, where: i.collection_id in ^ids, select: count(i.id))
      |> Repo.one(timeout: @timeout)

    ok(examples, items, count, "inscriptions in the collections we index")
  end

  defp fetch(%{kind: "template", template_hashes: hashes} = examples, limit) do
    items =
      from(t in Transaction,
        where: fragment("? && ?::varchar[]", t.output_template_hashes, ^hashes),
        where: not is_nil(t.block_height),
        order_by: [desc: t.block_height],
        limit: ^limit,
        select: %{txid: t.txid, block_height: t.block_height, note: nil}
      )
      |> Repo.all(timeout: @timeout)

    ok(examples, items, nil, nil)
  end

  defp fetch(%{kind: "protocol", protocols: protocols} = examples, limit) do
    items =
      from(t in Transaction,
        where: fragment("? @> ?::varchar[]", t.protocols, ^protocols),
        where: not is_nil(t.block_height),
        order_by: [desc: t.block_height],
        limit: ^limit,
        select: %{txid: t.txid, block_height: t.block_height, note: nil}
      )
      |> Repo.all(timeout: @timeout)

    ok(examples, items, nil, nil)
  end

  defp fetch(%{kind: "none"} = examples, _limit) do
    %{status: :coming, source: source(examples), count: nil, count_label: nil, items: []}
  end

  defp ok(examples, items, count, count_label) do
    %{status: :ok, source: source(examples), count: count, count_label: count_label, items: items}
  end

  # BSV-21 deploys are `deploy+mint` (partial index on op = 'deploy+mint');
  # classic BSV-20 deploys are `deploy` with a tick (partial index on tick).
  defp token_count(protocol_id, "bsv-21") do
    count =
      from(i in Instance,
        where: i.protocol_id == ^protocol_id,
        where: fragment("?->>'op' = 'deploy+mint'", i.parsed_data),
        select: count(i.id)
      )
      |> Repo.one(timeout: @timeout)

    {count, "tokens deployed"}
  end

  defp token_count(protocol_id, "bsv-20") do
    count =
      from(i in Instance,
        where: i.protocol_id == ^protocol_id,
        where: fragment("?->>'tick' IS NOT NULL", i.parsed_data),
        where: fragment("?->>'op' = 'deploy'", i.parsed_data),
        select: count(i.id)
      )
      |> Repo.one(timeout: @timeout)

    {count, "tickers deployed"}
  end

  defp token_count(_protocol_id, _standard), do: {nil, nil}

  defp token_example(row) do
    note =
      [row.op, row.name, row.amt && row.op != "deploy" && "amount #{row.amt}"]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")

    %{txid: row.txid, block_height: row.block_height, note: if(note == "", do: nil, else: note)}
  end
end
