defmodule Bitblocks.Bitcom.Snapshots do
  @moduledoc """
  Versioned copies of the Bitcom registry, so it doesn't depend on trusting
  bitblocks (#21).

  A snapshot is the registry as canonical JSON: keys sorted, namespaces sorted
  by address, and nothing that moves on its own (no timestamp, no usage
  count). So the same on-chain facts always give the same bytes and the same
  sha256, and a new version is written only when a fact changed.

  Each entry already carries the txids that prove it, so anyone can re-derive
  it from the chain. The stored bytes are what the API serves, so
  `sha256sum` on a download matches the listed hash.

  Anchoring a hash on chain (`$ echo <sha256> to registry.json`, from a
  bitblocks-owned address) is a wallet step and is not done here;
  `anchor_txid` holds that tx once one exists.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Bitcom
  alias Bitblocks.Bitcom.Snapshot
  alias Bitblocks.Repo

  @doc """
  The registry as canonical JSON and its hash:
  `%{body: json, sha256: hex, namespaces: n}`.
  """
  @spec build() :: %{body: String.t(), sha256: String.t(), namespaces: non_neg_integer()}
  def build do
    namespaces = Bitcom.snapshot_namespaces()

    body =
      %{spec: Bitcom.spec_url(), namespaces: namespaces}
      |> canonical()
      |> Jason.encode!()

    %{
      body: body,
      sha256: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower),
      namespaces: length(namespaces)
    }
  end

  @doc """
  Writes a new version if the registry changed since the latest one.
  Returns `{:ok, :created, snapshot}` or `{:ok, :unchanged, snapshot}`.
  """
  @spec take() :: {:ok, :created | :unchanged, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def take do
    built = build()

    case latest() do
      %Snapshot{sha256: sha256} = snapshot when sha256 == built.sha256 ->
        {:ok, :unchanged, snapshot}

      _ ->
        case %Snapshot{} |> Snapshot.changeset(built) |> Repo.insert() do
          {:ok, snapshot} ->
            Logger.info("Bitcom snapshot v#{snapshot.id}: #{snapshot.sha256}")
            {:ok, :created, snapshot}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc "The newest snapshot, or nil."
  @spec latest() :: Snapshot.t() | nil
  def latest do
    Repo.one(from s in Snapshot, order_by: [desc: s.id], limit: 1)
  end

  @doc "Snapshot `version`, or nil."
  @spec get(pos_integer()) :: Snapshot.t() | nil
  def get(version) when is_integer(version), do: Repo.get(Snapshot, version)

  @doc "Every version's metadata, newest first, without the bodies."
  @spec list(pos_integer()) :: [map()]
  def list(limit \\ 100) do
    from(s in Snapshot,
      order_by: [desc: s.id],
      limit: ^limit,
      select: %{
        version: s.id,
        sha256: s.sha256,
        namespaces: s.namespaces,
        anchor_txid: s.anchor_txid,
        taken_at: s.inserted_at
      }
    )
    |> Repo.all()
  end

  # Maps become ordered objects with sorted keys, all the way down.
  defp canonical(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
