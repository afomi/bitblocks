defmodule Bitblocks.Interop.Bsv402Vectors do
  @moduledoc """
  The published BSV 402 vectors, `GET /interop/bsv402/v0.json`
  (docs/BSV_402.md, section 6).

  The file is `priv/data/interop/bsv402_v0.json`, built by
  `scripts/bsv402_vectors_v0.exs` and held to `Bitblocks.Payments.Bsv402` by
  `test/bitblocks/payments/bsv402_test.exs`. It is read once at compile time,
  so serving it touches neither the database nor the disk.
  """

  @path Path.expand("../../../priv/data/interop/bsv402_v0.json", __DIR__)
  @external_resource @path

  @body File.read!(@path)
  @sha256 :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower)

  @doc "The published JSON, exactly as served."
  @spec body() :: String.t()
  def body, do: @body

  @doc "The hex sha256 of `body/0`."
  @spec sha256() :: String.t()
  def sha256, do: @sha256
end
