defmodule Bitblocks.Cluster.EC2TagsTest do
  use ExUnit.Case, async: true

  alias Cluster.Strategy.State
  alias Bitblocks.Cluster.EC2Tags

  doctest EC2Tags

  @describe_instances_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>8f7724cf-496f-496e-8fe3-example</requestId>
    <reservationSet>
      <item>
        <reservationId>r-1</reservationId>
        <instancesSet>
          <item>
            <instanceId>i-01e1ae4df516b8adc</instanceId>
            <privateIpAddress>10.0.3.192</privateIpAddress>
            <instanceState><code>16</code><name>running</name></instanceState>
          </item>
        </instancesSet>
      </item>
      <item>
        <reservationId>r-2</reservationId>
        <instancesSet>
          <item>
            <instanceId>i-0599c93a1f7d7f435</instanceId>
            <privateIpAddress>10.0.4.153</privateIpAddress>
            <instanceState><code>16</code><name>running</name></instanceState>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
  """

  describe "parse_private_ips/1" do
    test "returns every instance's private IP from a DescribeInstances response" do
      assert EC2Tags.parse_private_ips(@describe_instances_xml) == ["10.0.3.192", "10.0.4.153"]
    end

    test "returns no IPs when no instance matches" do
      xml = ~s(<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>)

      assert EC2Tags.parse_private_ips(xml) == []
    end
  end

  describe "node_names/2" do
    test "names each peer with this node's basename and leaves this node out" do
      assert EC2Tags.node_names(["10.0.3.192", "10.0.4.153"], :"bitblocks@10.0.4.153") ==
               [:"bitblocks@10.0.3.192"]
    end

    test "drops duplicates and anything that is not an IPv4 address" do
      ips = ["10.0.3.192", "10.0.3.192", "", "ip-10-0-4-153", "10.0.4", "10.0.4.153"]

      assert EC2Tags.node_names(ips, :"bitblocks@10.0.9.9") ==
               [:"bitblocks@10.0.3.192", :"bitblocks@10.0.4.153"]
    end
  end

  describe "boot safety" do
    test "starts without calling AWS and survives a failing lookup" do
      test_pid = self()

      list_ips = fn _config ->
        send(test_pid, :listed)
        raise "AWS is unreachable"
      end

      state = %State{
        topology: :ec2_test,
        connect: {:net_kernel, :connect_node, []},
        disconnect: {:erlang, :disconnect_node, []},
        list_nodes: {:erlang, :nodes, [:connected]},
        config: [tag_value: "bitblocks", polling_interval: 10, list_ips: list_ips]
      }

      pid = start_supervised!(%{id: :ec2_test, start: {EC2Tags, :start_link, [[state]]}})

      # The test VM runs without distribution, so the strategy must stay idle
      # (no AWS call) and keep polling without crashing.
      refute_receive :listed, 50
      assert %State{} = :sys.get_state(pid)
    end
  end
end
