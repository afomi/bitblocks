defmodule Bitblocks.ProtocolRegistrySeedTest do
  use Bitblocks.DataCase, async: true

  alias Bitblocks.ProtocolRegistry

  describe "seed_builtin_protocols/0" do
    test "credits AIP to attilaaf and does not credit HAIP to unwriter" do
      :ok = ProtocolRegistry.seed_builtin_protocols()

      aip = ProtocolRegistry.get_protocol_by_address("15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva")
      haip = ProtocolRegistry.get_protocol_by_address("1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3")

      assert aip.author == "attilaaf"
      refute haip.author == "unwriter"
    end

    test "points Metanet's documentation at nChain's technical summary" do
      :ok = ProtocolRegistry.seed_builtin_protocols()

      assert ProtocolRegistry.get_protocol_by_address("meta").documentation_url ==
               "https://nchain.com/wp-content/uploads/2022/09/The-Metanet-Technical-Summary-v1.0.pdf"
    end
  end
end
