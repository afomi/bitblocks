defmodule Bitblocks.RealHeaders do
  @moduledoc """
  Real mainnet headers, as a block explorer gives them, for tests that need a
  row to pass `Chain.HeaderVerifier` with its real proof of work. A wrong figure
  here fails that check, so these can't drift from the chain.
  """

  alias Bitblocks.Chain.Block
  alias Bitblocks.Repo

  @headers %{
    0 => %{
      hash: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
      prevblockhash: "",
      merkleroot: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
      version: 1,
      time: 1_231_006_505,
      bits: "1d00ffff",
      nonce: 2_083_236_893,
      num_tx: 1
    },
    9 => %{
      hash: "000000008d9dc510f23c2657fc4f67bea30078cc05a90eb89e84cc475c080805",
      prevblockhash: "00000000408c48f847aa786c2268fc3e6ec2af68e8468a34a28c61b7f1de0dc6",
      merkleroot: "0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9",
      version: 1,
      time: 1_231_473_279,
      bits: "1d00ffff",
      nonce: 1_397_702_696,
      num_tx: 1
    },
    170 => %{
      hash: "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee",
      prevblockhash: "000000002a22cfee1f2c846adbd12b3e183d4f97683f85dad08a79780a84bd55",
      merkleroot: "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff",
      version: 1,
      time: 1_231_731_025,
      bits: "1d00ffff",
      nonce: 1_889_418_792,
      num_tx: 2
    },
    # The block of BRC-74's example.
    813_706 => %{
      hash: "00000000000000000276ab84b3df90340381e62907fabe43db7b54aad06fb7bb",
      prevblockhash: "000000000000000002411567645bcf81ed6a051eb7422cc9a02e75352d7787dc",
      merkleroot: "57aab6e6fb1b697174ffb64e062c4728f2ffd33ddcfa02a43b64d8cd29b483b4",
      version: 779_640_832,
      time: 1_697_219_851,
      bits: "180f4efe",
      nonce: 1_986_833_432,
      num_tx: 3051
    },
    # The block of BRC-62's example.
    814_435 => %{
      hash: "000000000000000003f49bf7c058cc10c205b0fe381c218288bf92fd974c672b",
      prevblockhash: "00000000000000000684dca7db716a8bb6a0348fc76f0fcad723bee875c6c808",
      merkleroot: "bb6f640cc4ee56bf38eb5a1969ac0c16caa2d3d202b22bf3735d10eec0ca6e00",
      version: 594_247_680,
      time: 1_697_654_692,
      bits: "180c28d1",
      nonce: 1_783_718_184,
      num_tx: 106
    },
    # The block of woc_mainnet_v1.json and headers_v1.json.
    973_110 => %{
      hash: "0000000000000000028385c66577ddc13278af912119b97c4efdef1748fef8e9",
      prevblockhash: "00000000000000001ea0391d962a9911066e2a30b4b8c51c70f82786a20db3fc",
      merkleroot: "9f88d1a7da7f1cd99d15b72b69784712e6cc9ac38ef37142b481a165773f7ffe",
      version: 703_389_696,
      time: 1_793_241_562,
      bits: "182479cf",
      nonce: 3_907_804_537,
      num_tx: 0
    }
  }

  def fields(height), do: Map.fetch!(@headers, height)

  def heights, do: Map.keys(@headers)

  @doc "Stores the real header at `height`, with `overrides`."
  def insert(height, overrides \\ %{}) do
    Repo.insert!(
      struct(
        Block,
        height
        |> fields()
        |> Map.merge(%{height: height, sync_state: "header_only", tx: []})
        |> Map.merge(overrides)
      )
    )
  end
end
