defmodule Bitblocks.Interop.Vectors do
  @moduledoc """
  The published interoperability vectors, `GET /interop/vectors/v1.json`
  (`docs/INTEROP_KIT.md`).

  The file is `priv/data/interop/vectors_v1.json`, built by
  `scripts/interop_vectors_v1.exs` and held to `Beef.Reader` and `BeefVerifier`
  by `test/bitblocks/interop/vectors_test.exs`. It is read once at compile time,
  so serving it touches neither the database nor the disk.
  """

  @path Path.expand("../../../priv/data/interop/vectors_v1.json", __DIR__)
  @external_resource @path

  @license_path Path.expand("../../../priv/data/interop/OPEN-BSV-LICENSE.txt", __DIR__)
  @external_resource @license_path

  @license File.read!(@license_path)
  @body File.read!(@path)
  @sha256 :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower)

  @decoded Jason.decode!(@body)

  @summary %{
    version: @decoded["version"],
    total: length(@decoded["vectors"]),
    valid: Enum.count(@decoded["vectors"], & &1["valid"]),
    invalid: Enum.count(@decoded["vectors"], &(not &1["valid"])),
    beef: Enum.count(@decoded["vectors"], &(&1["kind"] == "beef")),
    bump: Enum.count(@decoded["vectors"], &(&1["kind"] == "bump"))
  }

  @doc "The Open BSV License, as `@bsv/sdk` 2.4.0 ships it."
  @spec license() :: String.t()
  def license, do: @license

  @doc "The published JSON, exactly as served."
  @spec body() :: String.t()
  def body, do: @body

  @doc "The hex sha256 of `body/0`."
  @spec sha256() :: String.t()
  def sha256, do: @sha256

  @doc "The counts and version a page shows, read from the file."
  @spec summary() :: map()
  def summary, do: @summary
end
