defmodule Bitblocks.NodeRole do
  @moduledoc """
  What this app node does: one writer leads the sync, and read-only nodes add
  web capacity and nothing else (#39).

  `NODE_ROLE=reader` (config/runtime.exs) starts a read-only node:

    * no Oban queues, so it never holds a block job, a backfill job or a
      `SyncHeadersWorker` job;
    * no Oban plugins and no leadership election, so no cron and no chance of
      being elected;
    * no `Sync.Coordinator`, so no header sync and no dispatch.

  It can still insert jobs; a writer runs them. Unset, a node is a `writer`,
  the only kind production runs today.

  Two writers stay safe too. Only the Oban leader runs tip sync and dispatch
  (`Sync.Coordinator`), and leadership lives in the database, so it holds
  without an Erlang cluster. Dispatch counts live block jobs in the database
  against the one concurrency setting, so block fetches, and the node's
  `getrawtransaction` streams with them, are bounded by that setting however
  many instances run.

  The rate limiter is the one thing that does depend on the cluster:
  `RateLimiter.Replicator` shares counts over PubSub, which reaches other
  nodes only while they are connected. `status/0` says which is true.
  """

  @type role :: :writer | :reader

  @doc "This node's role."
  @spec role() :: role()
  def role, do: Application.get_env(:bitblocks, :node_role, :writer)

  @doc "The Oban config for `role`: a reader runs nothing and leads nothing."
  @spec oban_config(keyword(), role()) :: keyword()
  def oban_config(config, role \\ role())
  def oban_config(config, :writer), do: config

  def oban_config(config, :reader),
    do: Keyword.merge(config, queues: [], plugins: [], peer: false)

  @doc "`child` on a writer; nothing on a reader. For the supervision tree."
  @spec writer_only(term(), role()) :: [term()]
  def writer_only(child, role \\ role())
  def writer_only(child, :writer), do: [child]
  def writer_only(_child, :reader), do: []

  @doc """
  This node, as data: `role`, `sync_writer` (it is leading the sync right
  now), `connected_nodes`, and `rate_limit_scope`: `"cluster"` while other
  nodes are connected, otherwise `"per_node"`.
  """
  @spec status(role(), [node()], (-> boolean())) :: %{
          role: String.t(),
          sync_writer: boolean(),
          connected_nodes: non_neg_integer(),
          rate_limit_scope: String.t()
        }
  def status(role \\ role(), nodes \\ Node.list(), leader? \\ &Oban.Peer.leader?/0) do
    %{
      role: Atom.to_string(role),
      sync_writer: role == :writer and leader?.(),
      connected_nodes: length(nodes),
      rate_limit_scope: if(nodes == [], do: "per_node", else: "cluster")
    }
  end
end
