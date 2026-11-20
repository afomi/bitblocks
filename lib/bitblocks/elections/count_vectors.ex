defmodule Bitblocks.Elections.CountVectors do
  @moduledoc """
  The published test vectors for the election counting rule,
  `GET /interop/elections/count/v1.json` (`docs/ELECTION_DOGFOOD.md`).

  The file is `priv/data/interop/election_count_v1.json`, with its expected
  outcomes written by hand, and held to `Bitblocks.Elections.Count` by
  `test/bitblocks/elections/count_test.exs`. It is read once at compile time,
  so serving it touches neither the database nor the disk.
  """

  @path Path.expand("../../../priv/data/interop/election_count_v1.json", __DIR__)
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
