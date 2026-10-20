defmodule Bitblocks.Tokens do
  @moduledoc """
  Context module for BSV-20 / BSV-21 fungible tokens.

  Tokens are indexed from 1Sat Ordinal inscriptions (see `Bitblocks.Bsv20Parser`)
  and stored as `protocol_instances` under the `BSV20` protocol — the same generic
  storage the Open Order Book uses. Each instance is one on-chain occurrence
  (`txid` + `vout`) of a token operation:

  - `deploy+mint` (BSV-21) — a token genesis. `token_id` = `"<txid>_<vout>"` of the
    mint output. The whole supply is minted in this one output. `state` tracks
    `supply` and a running `holders` count. **This id is exactly the `token_id`
    the Open Order Book carries**, so `get_token/1` resolves a listing's token.
  - `transfer` (BSV-21) — moves an `id`-referenced balance to a recipient address.
    Holder balances are derived by summing transfer `amt` per recipient.
  - classic BSV-20 (`deploy` / `mint` / `transfer`, ticker-based) — stored raw for
    visibility. First-is-first supply aggregation is deferred (detect-only in v1);
    these are surfaced by ticker but not reconciled against `max`.

  Read-only: this module indexes and queries tokens. Composing, signing, and
  broadcasting mint/transfer transactions is the wallet layer's job (qart), per
  the bitblocks read / qart write boundary.
  """

  import Ecto.Query, warn: false

  alias Bitblocks.Repo
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.ProtocolRegistry.Instance

  @pubsub Bitblocks.PubSub
  @topic "tokens"

  @doc """
  Subscribes the calling process to all token events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Subscribes the calling process to events for a single token.
  """
  def subscribe(token_id) when is_binary(token_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@topic}:#{token_id}")
  end

  # -- Indexing ---------------------------------------------------------------

  @doc """
  Indexes a token genesis (`deploy+mint`) as a `protocol_instance`.

  `attrs` carries `:txid`, `:vout`, optional block context, and `:token` — a
  `Bitblocks.Bsv20Parser` result map. The `token_id` is stamped as
  `"<txid>_<vout>"` (the caller's `token` map has `token_id: nil` for a mint).

  Broadcasts `{:new_token, token}`. Idempotent via the `[:txid, :vout]` unique
  constraint — a re-processed block does not double-insert.
  """
  def index_token(%{token: %{op: "deploy+mint"} = token} = attrs) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      txid = attrs[:txid] || attrs["txid"]
      vout = attrs[:vout] || attrs["vout"] || 0
      token_id = "#{txid}_#{vout}"

      # The mint output holds the whole supply; its recipient is the first holder.
      parsed_data =
        token
        |> stringify_token()
        |> Map.put("token_id", token_id)
        |> put_present("recipient", attrs[:recipient] || attrs["recipient"])

      instance_attrs = %{
        protocol_id: protocol_id,
        txid: txid,
        vout: vout,
        block_height: attrs[:block_height] || attrs["block_height"],
        block_hash: attrs[:block_hash] || attrs["block_hash"],
        parsed_data: parsed_data,
        state: %{"supply" => token.amt, "minted" => token.amt, "holders" => 0}
      }

      case ProtocolRegistry.create_instance(instance_attrs) do
        {:ok, instance} ->
          view = instance_to_token(instance)
          broadcast({:new_token, view})
          broadcast_token(token_id, {:new_token, view})
          {:ok, view}

        {:error, _} = error ->
          error
      end
    else
      _ -> {:error, :protocol_not_found}
    end
  end

  def index_token(_), do: {:error, :not_a_mint}

  @doc """
  Indexes a token `transfer`.

  For BSV-21 the transfer references a token by `token_id` (`id` in the
  inscription); `:recipient` (from the output's address) is recorded so holder
  balances can be summed. Classic ticker transfers are stored raw (detect-only).

  Broadcasts `{:token_transfer, transfer}`.
  """
  def index_transfer(%{token: %{op: "transfer"} = token} = attrs) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      txid = attrs[:txid] || attrs["txid"]
      vout = attrs[:vout] || attrs["vout"] || 0
      recipient = attrs[:recipient] || attrs["recipient"]

      parsed_data =
        token
        |> stringify_token()
        |> Map.put("recipient", recipient)

      instance_attrs = %{
        protocol_id: protocol_id,
        txid: txid,
        vout: vout,
        block_height: attrs[:block_height] || attrs["block_height"],
        block_hash: attrs[:block_hash] || attrs["block_hash"],
        parsed_data: parsed_data,
        state: %{}
      }

      case ProtocolRegistry.create_instance(instance_attrs) do
        {:ok, instance} ->
          view = instance_to_token(instance)
          broadcast({:token_transfer, view})
          if token.token_id, do: broadcast_token(token.token_id, {:token_transfer, view})
          {:ok, view}

        {:error, _} = error ->
          error
      end
    else
      _ -> {:error, :protocol_not_found}
    end
  end

  def index_transfer(_), do: {:error, :not_a_transfer}

  @doc """
  Indexes a classic BSV-20 op (`deploy` / `mint`) for visibility (detect-only).

  Stored raw with `standard: "bsv-20"`; no supply aggregation in v1.
  """
  def index_classic(%{token: %{standard: "bsv-20", op: op} = token} = attrs)
      when op in ["deploy", "mint"] do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      instance_attrs = %{
        protocol_id: protocol_id,
        txid: attrs[:txid] || attrs["txid"],
        vout: attrs[:vout] || attrs["vout"] || 0,
        block_height: attrs[:block_height] || attrs["block_height"],
        block_hash: attrs[:block_hash] || attrs["block_hash"],
        parsed_data: stringify_token(token),
        state: %{}
      }

      case ProtocolRegistry.create_instance(instance_attrs) do
        {:ok, instance} -> {:ok, instance_to_token(instance)}
        {:error, _} = error -> error
      end
    else
      _ -> {:error, :protocol_not_found}
    end
  end

  def index_classic(_), do: {:error, :not_classic}

  @doc """
  Routes a parsed token output to the correct indexer.

  `attrs` is `%{txid, vout, block_height, block_hash, recipient, token}`. Returns
  the indexer's result, or `{:ok, :ignored}` for ops not indexed in v1.
  """
  def index(%{token: %{op: "deploy+mint"}} = attrs), do: index_token(attrs)
  def index(%{token: %{op: "transfer"}} = attrs), do: index_transfer(attrs)

  def index(%{token: %{standard: "bsv-20", op: op}} = attrs) when op in ["deploy", "mint"],
    do: index_classic(attrs)

  def index(_), do: {:ok, :ignored}

  # -- Queries ----------------------------------------------------------------

  @doc """
  Unspent token outputs held by `address` — the wallet-basket view
  (BRC-163 basket `bsv21`).

  An output is unspent when no `spend_index` row spends it, so the answer is
  only as current as the sync. Each entry carries `txid`, `vout`, `token_id`,
  `standard`, `op`, `amt` (string, as inscribed), `sym`/`dec` (from the
  token's mint), `satoshis`, `locking_script` (hex), `height`, and
  `confirmations`.

  ## Options

    * `:standard` — `"bsv-21"` or `"bsv-20"` (default: both)
    * `:token_id` — only this token
  """
  def unspent_outputs(address, opts \\ []) when is_binary(address) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      instances =
        protocol_id
        |> unspent_query()
        |> where([i], fragment("?->>'recipient' = ?", i.parsed_data, ^address))
        |> filter_standard(opts[:standard])
        |> filter_token_id(opts[:token_id])
        |> order_by([i], asc: i.block_height, asc: i.id)
        |> Repo.all()

      scripts = locking_scripts(instances)
      tip = tip_height()

      mints =
        instances
        |> Enum.map(& &1.parsed_data["token_id"])
        |> Enum.uniq()
        |> Map.new(fn id -> {id, get_token(id)} end)

      Enum.map(instances, fn i ->
        pd = i.parsed_data
        mint = mints[pd["token_id"]] || %{}
        {satoshis, script} = Map.get(scripts, {i.txid, i.vout}, {nil, nil})

        %{
          txid: i.txid,
          vout: i.vout,
          token_id: pd["token_id"],
          standard: pd["standard"],
          op: pd["op"],
          amt: pd["amt"],
          sym: mint[:sym],
          dec: mint[:dec],
          satoshis: satoshis,
          locking_script: script,
          height: i.block_height,
          confirmations: confirmations(tip, i.block_height)
        }
      end)
    else
      _ -> []
    end
  end

  # BSV20 mint/transfer instances whose outpoint has no spend_index row.
  defp unspent_query(protocol_id) do
    from(i in Instance,
      where: i.protocol_id == ^protocol_id,
      where:
        fragment("?->>'op' = 'deploy+mint'", i.parsed_data) or
          fragment("?->>'op' = 'transfer'", i.parsed_data),
      where:
        not exists(
          from(s in Bitblocks.Chain.Spend,
            where: s.txid == parent_as(:instance).txid and s.vout == parent_as(:instance).vout
          )
        )
    )
    |> then(&from(i in &1, as: :instance))
  end

  defp filter_token_id(query, nil), do: query

  defp filter_token_id(query, token_id),
    do: where(query, [i], fragment("?->>'token_id' = ?", i.parsed_data, ^token_id))

  # {txid, vout} => {satoshis, locking script hex}, decoded from stored raw txs.
  defp locking_scripts([]), do: %{}

  defp locking_scripts(instances) do
    txids = instances |> Enum.map(& &1.txid) |> Enum.uniq()

    from(t in Bitblocks.Chain.Transaction, where: t.txid in ^txids, select: {t.txid, t.raw})
    |> Repo.all()
    |> Enum.flat_map(fn {txid, raw} ->
      case Bitblocks.Chain.SafeTx.from_hex(raw) do
        {:ok, tx} ->
          tx.outputs
          |> Enum.with_index()
          |> Enum.map(fn {out, vout} ->
            {{txid, vout}, {out.satoshis, BSV.Script.to_binary(out.script, encoding: :hex)}}
          end)

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp tip_height do
    case Bitblocks.Chain.get_latest_block() do
      %{height: height} -> height
      _ -> nil
    end
  end

  defp confirmations(tip, height) when is_integer(tip) and is_integer(height),
    do: max(tip - height + 1, 0)

  defp confirmations(_tip, _height), do: 0

  @doc """
  Gets a token by its `token_id` (`"<txid>_<vout>"`, BSV-21) or its `tick`
  (BSV-20 classic — returns the first-seen deploy for the ticker).

  Returns a token view map, or `nil`. This is the function the Open Order Book
  links against so a listing's `token_id` resolves to a real token.
  """
  def get_token(id) when is_binary(id) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      instance =
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where:
            fragment("?->>'op' = 'deploy+mint'", i.parsed_data) or
              fragment("?->>'op' = 'deploy'", i.parsed_data),
          where:
            fragment("?->>'token_id' = ?", i.parsed_data, ^id) or
              fragment("?->>'tick' = ?", i.parsed_data, ^id),
          order_by: [asc: i.block_height, asc: i.id],
          limit: 1
        )
        |> Repo.one()

      case instance do
        nil -> nil
        instance -> instance_to_token(instance)
      end
    else
      _ -> nil
    end
  end

  @doc """
  Lists indexed tokens (deploy+mint genesis records), most recent first.

  ## Options

    * `:standard` — `"bsv-21"` or `"bsv-20"`
    * `:sym`      — filter by symbol (BSV-21) — exact match
    * `:limit`    — max results (default 50)
    * `:cursor`   — pagination cursor (instance ID)
  """
  def list_tokens(opts \\ []) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      from(i in Instance,
        where: i.protocol_id == ^protocol_id,
        where:
          fragment("?->>'op' = 'deploy+mint'", i.parsed_data) or
            fragment("?->>'op' = 'deploy'", i.parsed_data),
        order_by: [desc: i.id]
      )
      |> filter_standard(opts[:standard])
      |> filter_sym(opts[:sym])
      |> apply_cursor(opts[:cursor])
      |> limit(^Keyword.get(opts, :limit, 50))
      |> Repo.all()
      |> Enum.map(&instance_to_token/1)
    else
      _ -> []
    end
  end

  @doc """
  Returns holder balances for a token, derived by summing `transfer` amounts per
  recipient address. Most-held first.

  Net balances: the sum of each address's *unspent* token outputs (the mint
  output and transfer outputs with no `spend_index` row). Returns
  `[%{address: addr, balance: integer}, ...]`, largest first.
  """
  def token_holders(token_id) when is_binary(token_id) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      protocol_id
      |> unspent_query()
      |> where([i], fragment("?->>'token_id' = ?", i.parsed_data, ^token_id))
      |> where([i], fragment("?->>'recipient' IS NOT NULL", i.parsed_data))
      |> select([i], %{
        address: fragment("?->>'recipient'", i.parsed_data),
        amt: fragment("?->>'amt'", i.parsed_data)
      })
      |> Repo.all()
      |> Enum.group_by(& &1.address)
      |> Enum.map(fn {address, rows} ->
        %{address: address, balance: Enum.reduce(rows, 0, &(to_integer(&1.amt) + &2))}
      end)
      |> Enum.sort_by(& &1.balance, :desc)
    else
      _ -> []
    end
  end

  @doc """
  Returns `address`'s net (unspent) balance of `token_id`.
  """
  def balance_of(token_id, address) when is_binary(token_id) and is_binary(address) do
    token_id
    |> token_holders()
    |> Enum.find(%{balance: 0}, &(&1.address == address))
    |> Map.get(:balance)
  end

  @doc """
  Returns recent transfers for a token, most recent first.
  """
  def token_transfers(token_id, opts \\ []) when is_binary(token_id) do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      from(i in Instance,
        where: i.protocol_id == ^protocol_id,
        where: fragment("?->>'op' = 'transfer'", i.parsed_data),
        where: fragment("?->>'token_id' = ?", i.parsed_data, ^token_id),
        order_by: [desc: i.id],
        limit: ^Keyword.get(opts, :limit, 50)
      )
      |> Repo.all()
      |> Enum.map(&instance_to_token/1)
    else
      _ -> []
    end
  end

  @doc """
  Returns aggregate token statistics.
  """
  def token_stats do
    with protocol_id when not is_nil(protocol_id) <- get_protocol_id() do
      count = fn frag ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: ^frag,
          select: count(i.id)
        )
        |> Repo.one() || 0
      end

      %{
        total_tokens: count.(dynamic([i], fragment("?->>'op' = 'deploy+mint'", i.parsed_data))),
        total_transfers: count.(dynamic([i], fragment("?->>'op' = 'transfer'", i.parsed_data))),
        classic_ops: count.(dynamic([i], fragment("?->>'standard' = 'bsv-20'", i.parsed_data)))
      }
    else
      _ -> %{total_tokens: 0, total_transfers: 0, classic_ops: 0}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp filter_standard(query, nil), do: query

  defp filter_standard(query, standard) when is_binary(standard) do
    from i in query, where: fragment("?->>'standard' = ?", i.parsed_data, ^standard)
  end

  defp filter_sym(query, nil), do: query

  defp filter_sym(query, sym) when is_binary(sym) do
    from i in query, where: fragment("?->>'sym' = ?", i.parsed_data, ^sym)
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {id, _} -> from i in query, where: i.id < ^id
      :error -> query
    end
  end

  defp apply_cursor(query, cursor) when is_integer(cursor),
    do: from(i in query, where: i.id < ^cursor)

  defp instance_to_token(%Instance{} = i) do
    pd = i.parsed_data || %{}
    state = i.state || %{}

    %{
      id: i.id,
      txid: i.txid,
      vout: i.vout,
      block_height: i.block_height,
      standard: pd["standard"],
      op: pd["op"],
      token_id: pd["token_id"],
      tick: pd["tick"],
      sym: pd["sym"],
      amt: pd["amt"],
      max: pd["max"],
      lim: pd["lim"],
      dec: pd["dec"],
      icon: pd["icon"],
      recipient: pd["recipient"],
      supply: state["supply"],
      minted: state["minted"],
      holders: state["holders"],
      inserted_at: i.inserted_at
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Token map (atom keys) -> string-keyed map for JSONB storage, dropping nils.
  defp stringify_token(token) when is_map(token) do
    token
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp get_protocol_id do
    case ProtocolRegistry.get_protocol_by_name("BSV20") do
      nil -> nil
      protocol -> protocol.id
    end
  end

  defp to_integer(val) when is_integer(val), do: val

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_integer(_), do: 0

  defp broadcast(event), do: Phoenix.PubSub.broadcast(@pubsub, @topic, event)

  defp broadcast_token(nil, _event), do: :ok

  defp broadcast_token(token_id, event),
    do: Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:#{token_id}", event)
end
