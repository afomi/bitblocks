defmodule Bitblocks.Cluster.EC2Tags do
  @moduledoc """
  libcluster strategy: find peer nodes by EC2 tag.

  Every few seconds it lists the running EC2 instances whose tag matches
  (`Name=bitblocks` in production), turns each private IP into a node name with
  this node's basename (`bitblocks@10.0.3.192`), and connects to them.
  Nodes that drop out of the list are disconnected.

  Discovery needs no registration step, so a new instance joins as soon as it is
  running and a terminated one leaves on its own.
  Nothing here can stop the app booting: `init/1` returns at once, and an AWS or
  parse failure is logged and retried on the next poll.

  Infra side (security group ports, the `ec2:DescribeInstances` grant, rollout):
  `enable_ec2_tag_clustering` in the infra repo's `apps/bitblocks`.

  ## Config

    * `:tag_name` - the EC2 tag key to match (default `"Name"`)
    * `:tag_value` - the tag value to match (required)
    * `:region` - AWS region of the instances (default `"us-east-1"`)
    * `:polling_interval` - milliseconds between polls (default `5_000`)
    * `:list_ips` - a 1-arity function given the config, returning
      `{:ok, [ip]}` or `{:error, reason}`; defaults to the EC2 API call.
      Tests replace it.
  """

  use GenServer
  use Cluster.Strategy

  import Cluster.Logger
  import SweetXml, only: [sigil_x: 2]

  alias Cluster.Strategy
  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @ec2_api_version "2016-11-15"

  @impl Cluster.Strategy
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  def init([%State{} = state]) do
    send(self(), :poll)
    {:ok, %State{state | meta: MapSet.new()}}
  end

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp poll(%State{} = state) do
    state = if clusterable?(node()), do: sync(state), else: state

    Process.send_after(
      self(),
      :poll,
      Keyword.get(state.config, :polling_interval, @default_polling_interval)
    )

    state
  end

  # A node without distribution (nonode@nohost), or one that fell back to
  # 127.0.0.1 because rel/env.sh.eex got no IP from IMDS, has no address its
  # peers can reach, so it stays out of the cluster.
  defp clusterable?(self_node) do
    Node.alive?() and not String.ends_with?(Atom.to_string(self_node), "@127.0.0.1")
  end

  defp sync(%State{topology: topology, config: config} = state) do
    case safe_list_ips(config) do
      {:ok, ips} ->
        nodes = ips |> node_names(node()) |> MapSet.new()
        connect(state, disconnect(state, nodes))

      {:error, reason} ->
        warn(topology, "EC2 tag discovery failed, keeping current peers: #{inspect(reason)}")
        state
    end
  end

  defp disconnect(
         %State{
           topology: topology,
           disconnect: disconnect,
           list_nodes: list_nodes,
           meta: previous
         },
         nodes
       ) do
    removed = MapSet.difference(previous, nodes)

    case Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
      :ok ->
        nodes

      {:error, bad_nodes} ->
        Enum.reduce(bad_nodes, nodes, fn {n, _}, acc -> MapSet.put(acc, n) end)
    end
  end

  defp connect(
         %State{topology: topology, connect: connect, list_nodes: list_nodes} = state,
         nodes
       ) do
    nodes =
      case Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(nodes)) do
        :ok ->
          nodes

        {:error, bad_nodes} ->
          Enum.reduce(bad_nodes, nodes, fn {n, _}, acc -> MapSet.delete(acc, n) end)
      end

    %State{state | meta: nodes}
  end

  defp safe_list_ips(config) do
    list_ips = Keyword.get(config, :list_ips, &describe_instance_ips/1)
    list_ips.(config)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Builds peer node names from private IPs, using this node's basename.
  Drops this node itself and anything that is not an IPv4 address.

      iex> Bitblocks.Cluster.EC2Tags.node_names(["10.0.3.192", "10.0.4.153"], :"bitblocks@10.0.3.192")
      [:"bitblocks@10.0.4.153"]
  """
  @spec node_names([String.t()], node()) :: [node()]
  def node_names(ips, self_node) do
    [basename | _] = self_node |> Atom.to_string() |> String.split("@")

    ips
    |> Enum.filter(&ipv4?/1)
    |> Enum.uniq()
    # Bounded input: validated IPv4 addresses of this app's own instances.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    |> Enum.map(&String.to_atom("#{basename}@#{&1}"))
    |> Enum.reject(&(&1 == self_node))
  end

  defp ipv4?(ip) do
    match?({:ok, {_, _, _, _}}, :inet.parse_ipv4strict_address(String.to_charlist(ip)))
  end

  @doc """
  Extracts the private IPs from an EC2 `DescribeInstances` XML response.
  """
  @spec parse_private_ips(String.t()) :: [String.t()]
  def parse_private_ips(xml) do
    xml
    |> SweetXml.xpath(~x"//reservationSet/item/instancesSet/item/privateIpAddress/text()"ls)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def describe_instance_ips(config) do
    tag_name = Keyword.get(config, :tag_name, "Name")
    tag_value = Keyword.fetch!(config, :tag_value)
    region = Keyword.get(config, :region, "us-east-1")

    operation = %ExAws.Operation.Query{
      path: "/",
      service: :ec2,
      action: :describe_instances,
      params: %{
        "Action" => "DescribeInstances",
        "Version" => @ec2_api_version,
        "Filter.1.Name" => "tag:#{tag_name}",
        "Filter.1.Value.1" => tag_value,
        "Filter.2.Name" => "instance-state-name",
        "Filter.2.Value.1" => "running"
      }
    }

    case ExAws.request(operation, region: region) do
      {:ok, %{body: body}} when is_binary(body) -> {:ok, parse_private_ips(body)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
