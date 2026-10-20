defmodule Bitblocks.Bitcom do
  @moduledoc """
  A live Bitcom registry: indexes unwriter's Bitcom commands and serves each
  namespace's files and routes.

  Spec: https://github.com/unwriter/Bitcom (`bin/`, `0.1.0.md`). Bitcom treats
  the chain as a Unix computer: every address is a user, and a user writes into
  its own home with `$` commands. A command speaks for the address that funded
  the tx (its first input) — that is the only authentication Bitcom has.

      $ useradd <address>                         claim <address> (actor must be <address>)
      $ echo <content> to <file>                  write <file> in the actor's namespace
      $ cat bit://<address>/<txid> to <file>      point <file> at content in another tx
      $ route enable <matcher>                    the admin opens a route on its namespace
      $ route add <address> <matcher> <endpoint>  a provider (not the admin) serves that route

  Every command is logged in `bitcom_commands`, valid or not (`Bitblocks.Bitcom.Command`).
  Files and routes are read from the valid entries; the latest write wins.
  """

  import Ecto.Query

  alias Bitblocks.Bitcom.{Command, Route}
  alias Bitblocks.Chain.SafeTx
  alias Bitblocks.Protocol.Context
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.Repo
  alias Bitblocks.Script.OpReturn

  @dollar "$"
  @pipe "|"

  ## Parsing

  @doc """
  The Bitcom commands in a decoded tx, as `Command` attribute maps.

  A command is a `$` push at the start of an OP_RETURN or right after a `|`,
  followed by pushes up to the next `|`.
  """
  @spec commands(BSV.Tx.t(), keyword()) :: [map()]
  def commands(%BSV.Tx{outputs: outputs} = tx, opts \\ []) do
    actor = Context.first_input_address(tx)
    txid = Keyword.get_lazy(opts, :txid, fn -> BSV.Tx.get_txid(tx) end)
    block_height = Keyword.get(opts, :block_height)

    outputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {output, index} ->
      case command_pushes(OpReturn.raw_chunks(output.script)) do
        nil ->
          []

        pushes ->
          [
            pushes
            |> interpret(actor)
            |> Map.merge(%{txid: txid, output_index: index, block_height: block_height})
          ]
      end
    end)
  end

  # The pushes of the first `$` segment (command word first), or nil.
  defp command_pushes(chunks) do
    chunks
    |> Enum.chunk_by(&(&1 == @pipe))
    |> Enum.find_value(fn
      [@dollar | rest] -> Enum.take_while(rest, &is_binary/1)
      _ -> nil
    end)
  end

  defp interpret([], actor),
    do: invalid(%{actor: actor, command: @dollar, args: []}, "missing command")

  defp interpret([command | args], actor) do
    command = text(command)
    args = Enum.map(args, &text/1)
    base = %{actor: actor, command: command, args: args}

    if is_nil(actor),
      do: invalid(base, "funding input is not P2PKH; author unknown"),
      else: interpret(command, args, base)
  end

  defp interpret("useradd", [address], %{actor: actor} = base) do
    if address == actor,
      do: valid(base, %{namespace: address}),
      else: invalid(Map.put(base, :namespace, address), "useradd not funded by #{address}")
  end

  defp interpret("echo", [content, "to", file], base) when file != "",
    do: valid(base, %{namespace: base.actor, content: content, file: file})

  defp interpret("cat", ["bit://" <> _ = locator, "to", file], base) when file != "",
    do: valid(base, %{namespace: base.actor, locator: locator, file: file})

  defp interpret("route", ["enable", matcher], base) when matcher != "",
    do: valid(base, %{namespace: base.actor, route_matcher: matcher})

  defp interpret("route", ["add", address, matcher, endpoint], %{actor: actor} = base)
       when matcher != "" and endpoint != "" do
    attrs = %{namespace: address, route_matcher: matcher, endpoint: endpoint}

    if address == actor,
      do: invalid(Map.merge(base, attrs), "the admin enables routes; a provider adds them"),
      else: valid(base, attrs)
  end

  defp interpret(command, _args, base)
       when command in ["useradd", "echo", "cat", "route"],
       do: invalid(base, "malformed #{command}")

  defp interpret(command, _args, base), do: invalid(base, "unknown command #{inspect(command)}")

  defp valid(base, attrs), do: base |> Map.merge(attrs) |> Map.merge(%{valid: true, reason: nil})

  defp invalid(base, reason), do: Map.merge(base, %{valid: false, reason: reason})

  # Text columns hold UTF-8; other bytes are kept as "0x<hex>".
  defp text(bytes) when is_binary(bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
      do: bytes,
      else: "0x" <> Base.encode16(bytes, case: :lower)
  end

  ## Composing

  @doc """
  Builds the unsigned OP_RETURN for a command that `funder` will pay for.

  `pushes` is the command word and its args, without the `$`
  (`["echo", "hello", "to", "readme"]`). The command is checked with the same
  rules the indexer applies, so a composed command indexes as valid once a
  tx funded by `funder` carries it. Signing and broadcasting are the wallet's
  job (qart).

  Returns `{:ok, %{script_hex, asm, pushes, funder, namespace}}` or
  `{:error, reason}`.
  """
  def compose(pushes, funder) when is_list(pushes) and is_binary(funder) do
    with true <- address?(funder) || {:error, "funder is not a valid address"},
         true <- Enum.all?(pushes, &is_binary/1) || {:error, "every push must be a string"},
         %{valid: true} = command <- interpret(pushes, funder) do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, @dollar | pushes]}

      {:ok,
       %{
         script_hex: BSV.Script.to_binary(script, encoding: :hex),
         asm: BSV.Script.to_asm(script),
         pushes: [@dollar | pushes],
         funder: funder,
         namespace: command.namespace
       }}
    else
      %{valid: false, reason: reason} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  ## Indexing

  @doc """
  Logs every Bitcom command in a stored transaction and records `useradd`
  ownership proofs. Idempotent (one row per txid + output).

  Returns `{:ok, %{commands: logged, proofs: proven}}`, or `{:ok, %{commands: 0, proofs: 0}}`
  when the tx isn't tagged Bitcom or can't be decoded.
  """
  def index(%{txid: txid, raw: raw, protocols: protocols} = tx)
      when is_binary(raw) and is_list(protocols) do
    with true <- "Bitcom" in protocols,
         {:ok, decoded} <- SafeTx.from_hex(raw) do
      commands = commands(decoded, txid: txid, block_height: Map.get(tx, :block_height))
      logged = Enum.count(commands, &log/1)
      {:ok, %{commands: logged, proofs: prove(commands, txid)}}
    else
      _ -> {:ok, %{commands: 0, proofs: 0}}
    end
  end

  def index(_), do: {:ok, %{commands: 0, proofs: 0}}

  defp log(attrs) do
    %Command{}
    |> Command.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:txid, :output_index])
    |> case do
      {:ok, %Command{id: id}} when not is_nil(id) -> true
      _ -> false
    end
  end

  defp prove(commands, txid) do
    commands
    |> Enum.filter(&(&1.valid and &1.command == "useradd"))
    |> Enum.map(& &1.namespace)
    |> Enum.uniq()
    |> Enum.reduce(0, fn address, acc ->
      case ProtocolRegistry.prove_ownership(address, txid) do
        {:ok, count} -> acc + count
        _ -> acc
      end
    end)
  end

  ## Reading

  @doc "Every logged command for `namespace`, newest first (valid or not)."
  def history(namespace) when is_binary(namespace) do
    from(c in Command, where: c.namespace == ^namespace)
    |> newest_first()
    |> Repo.all()
  end

  @doc """
  The namespace's files: `[%{file, command, history}]`, sorted by name.
  `command` is the latest valid `echo`/`cat` to that file; `history` is every
  valid write, newest first.
  """
  def files(namespace) when is_binary(namespace) do
    from(c in Command,
      where: c.namespace == ^namespace and c.valid and c.command in ["echo", "cat"]
    )
    |> newest_first()
    |> Repo.all()
    |> Enum.group_by(& &1.file)
    |> Enum.map(fn {file, [latest | _] = writes} ->
      %{file: file, command: latest, history: writes}
    end)
    |> Enum.sort_by(& &1.file)
  end

  @doc """
  The namespace's enabled routes, each with the endpoints providers added:
  `[%{matcher, enabled_by, endpoints: [%{provider, endpoint, txid}]}]`.
  Endpoints added for a route the admin never enabled are left out.
  """
  def routes(namespace) when is_binary(namespace) do
    valid = from(c in Command, where: c.namespace == ^namespace and c.valid)

    enabled =
      from(c in valid, where: c.command == "route" and fragment("?[1]", c.args) == "enable")
      |> oldest_first()
      |> Repo.all()
      |> Enum.uniq_by(& &1.route_matcher)

    added =
      from(c in valid, where: c.command == "route" and fragment("?[1]", c.args) == "add")
      |> oldest_first()
      |> Repo.all()
      |> Enum.group_by(& &1.route_matcher)

    Enum.map(enabled, fn route ->
      endpoints =
        added
        |> Map.get(route.route_matcher, [])
        |> Enum.uniq_by(&{&1.actor, &1.endpoint})
        |> Enum.map(&%{provider: &1.actor, endpoint: &1.endpoint, txid: &1.txid})

      %{matcher: route.route_matcher, enabled_by: route.txid, endpoints: endpoints}
    end)
  end

  @doc """
  Resolves `bit://<namespace><path>`: the first enabled route whose matcher
  matches `path`, with each provider's endpoint instantiated.

  Returns `{:ok, %{matcher, captures, endpoints: [%{provider, url, txid}]}}`
  or `{:error, :no_route}`. Endpoints are returned, never fetched — the client
  picks a provider.
  """
  def resolve(namespace, path) when is_binary(namespace) and is_binary(path) do
    namespace
    |> routes()
    |> Enum.find_value({:error, :no_route}, fn route ->
      case Route.match(route.matcher, path) do
        {:ok, captures} ->
          endpoints =
            Enum.map(route.endpoints, fn ep ->
              %{
                provider: ep.provider,
                url: Route.instantiate(ep.endpoint, captures),
                txid: ep.txid
              }
            end)

          {:ok, %{matcher: route.matcher, captures: captures, endpoints: endpoints}}

        :nomatch ->
          nil
      end
    end)
  end

  @doc "Distinct namespaces with at least one valid command."
  def namespaces do
    from(c in Command,
      where: c.valid and not is_nil(c.namespace),
      distinct: true,
      select: c.namespace
    )
    |> Repo.all()
  end

  ## Directory

  # Usage counts stop here so the directory never scans a whole protocol's
  # history (B:// alone is millions of txs); shown as "10,000+".
  @usage_cap 10_000

  @doc "The cap on `usage` counts in `directory/0` and `entry/1`."
  def usage_cap, do: @usage_cap

  @typedoc """
  One namespace in the directory.

    * `tier` — `:proven` (a valid `$ useradd` funded by the address),
      `:self_described` (the owner wrote files), or `:listed` (known only from
      the registry seed or a protocol handler; no on-chain word from the owner).
    * `tag` — the protocol tag bitblocks puts on matching txs, when one exists.
    * `usage` — matching indexed txs, capped at `usage_cap/0`.
  """
  @type entry :: %{
          address: String.t(),
          name: String.t(),
          tier: :proven | :self_described | :listed,
          proof_txid: String.t() | nil,
          tag: String.t() | nil,
          files: non_neg_integer(),
          routes: non_neg_integer(),
          usage: non_neg_integer()
        }

  @doc """
  Every Bitcom namespace bitblocks knows: registered protocols with a Bitcom
  address, protocol handlers keyed by a Bitcom prefix, and addresses that
  issued a valid command. Proven first, then self-described, then listed;
  busiest first within a tier.
  """
  @spec directory() :: [entry()]
  def directory do
    known_addresses()
    |> Enum.map(&entry/1)
    |> Enum.sort_by(&{tier_rank(&1.tier), -&1.usage, &1.name})
  end

  @doc "The directory entry for one address (an empty `:listed` entry if unknown)."
  @spec entry(String.t()) :: entry()
  def entry(address) when is_binary(address) do
    protocol = ProtocolRegistry.get_protocol_by_address(address)
    tag = tag(address)
    proof = (protocol && protocol.ownership_proof_txid) || useradd_txid(address)
    files = count_files(address)

    %{
      address: address,
      name: name(protocol, tag, address),
      tier:
        cond do
          proof -> :proven
          files > 0 -> :self_described
          true -> :listed
        end,
      proof_txid: proof,
      tag: tag,
      files: files,
      routes: length(routes(address)),
      usage: usage(tag)
    }
  end

  @doc """
  A namespace as plain data, carrying every txid needed to re-verify it from
  the chain: the ownership proof, each file's latest write, and each route's
  enable and add txs. The shape served by the JSON API and `/bitcom.json`.
  """
  def export_namespace(address) when is_binary(address) do
    entry = entry(address)

    %{
      address: entry.address,
      name: entry.name,
      tier: Atom.to_string(entry.tier),
      proof_txid: entry.proof_txid,
      tag: entry.tag,
      indexed_txs: entry.usage,
      indexed_txs_capped: entry.usage >= @usage_cap,
      files:
        Enum.map(files(address), fn %{file: file, command: c, history: history} ->
          %{
            file: file,
            command: c.command,
            content: c.content,
            locator: c.locator,
            txid: c.txid,
            block_height: c.block_height,
            versions: length(history)
          }
        end),
      routes:
        Enum.map(routes(address), fn route ->
          %{
            matcher: route.matcher,
            uri: "bit://#{address}#{route.matcher}",
            enabled_txid: route.enabled_by,
            endpoints: route.endpoints
          }
        end)
    }
  end

  @doc "The whole registry as plain data (see `export_namespace/1`)."
  def export do
    %{
      spec: "https://github.com/unwriter/Bitcom",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      namespaces: Enum.map(directory(), &export_namespace(&1.address))
    }
  end

  @doc "The latest indexed txs carrying the address's protocol tag."
  def recent_transactions(address, limit \\ 10) do
    case tag(address) do
      nil ->
        []

      tag ->
        from(t in Bitblocks.Chain.Transaction,
          where: fragment("? @> ARRAY[?]::varchar[]", t.protocols, ^tag),
          order_by: [desc: t.id],
          limit: ^limit,
          select: %{txid: t.txid, block_height: t.block_height}
        )
        |> Repo.all()
    end
  end

  @doc "True for a base58check P2PKH address (mainnet or testnet)."
  def address?(address) when is_binary(address) do
    match?(
      {:ok, {<<_::binary-20>>, v}} when v in [<<0x00>>, <<0x6F>>],
      B58.decode58_check(address)
    )
  rescue
    _ -> false
  end

  def address?(_), do: false

  defp known_addresses do
    registered =
      from(p in ProtocolRegistry.Protocol, distinct: true, select: p.address)
      |> Repo.all()

    handled = Enum.map(prefix_handlers(), &elem(&1, 0))

    (registered ++ handled ++ namespaces())
    |> Enum.uniq()
    |> Enum.filter(&address?/1)
  end

  # {address, tag} for every handler keyed by a Bitcom prefix address.
  defp prefix_handlers do
    for handler <- Bitblocks.Protocol.Handlers.all(),
        {:prefix, address} <- [handler.segment_matcher()],
        address?(address),
        do: {address, handler.name()}
  end

  defp tag(address) do
    Enum.find_value(prefix_handlers(), fn {a, name} -> if a == address, do: name end)
  end

  defp name(%{name: name}, _tag, address) when is_binary(name) and name != address, do: name
  defp name(_protocol, tag, _address) when is_binary(tag), do: tag
  defp name(_protocol, _tag, address), do: address

  defp useradd_txid(address) do
    from(c in Command,
      where: c.namespace == ^address and c.valid and c.command == "useradd",
      order_by: [asc_nulls_last: c.block_height, asc: c.id],
      limit: 1,
      select: c.txid
    )
    |> Repo.one()
  end

  defp count_files(address) do
    from(c in Command,
      where: c.namespace == ^address and c.valid and c.command in ["echo", "cat"],
      select: count(c.file, :distinct)
    )
    |> Repo.one()
  end

  defp usage(nil), do: 0

  defp usage(tag) do
    capped =
      from(t in Bitblocks.Chain.Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.protocols, ^tag),
        limit: @usage_cap,
        select: t.id
      )

    Repo.one(from(s in subquery(capped), select: count()))
  end

  defp tier_rank(:proven), do: 0
  defp tier_rank(:self_described), do: 1
  defp tier_rank(:listed), do: 2

  # Unconfirmed (nil height) is newest.
  defp newest_first(query),
    do: order_by(query, [c], desc_nulls_first: c.block_height, desc: c.id)

  defp oldest_first(query),
    do: order_by(query, [c], asc_nulls_last: c.block_height, asc: c.id)
end
