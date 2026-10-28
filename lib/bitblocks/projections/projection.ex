defmodule Bitblocks.Projections.Projection do
  @moduledoc """
  A tenant's filter over the tag columns on `transactions`. See
  `Bitblocks.Projections` and docs/MANAGED_SERVICES.md.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Ingest-time tag columns, each GIN-indexed, so a containment filter on any
  # of them is an index lookup rather than a scan of `transactions`.
  @tag_columns ~w(output_addresses protocols output_script_hashes output_template_hashes aip_signers)
  @statuses ~w(active paused)

  @type t :: %__MODULE__{}

  schema "projections" do
    field :tenant, :string
    field :name, :string
    # Tag column => values; see the migration for the matching rule.
    field :filter, :map
    field :definition_hash, :string
    # First block covered; status/1 measures completeness from here.
    field :from_height, :integer, default: 0
    # Operator intent (active | paused); index readiness is computed, not stored.
    field :status, :string, default: "active"
    # Where new matches and reorg rewinds are POSTed; nil means hydrate-only.
    field :webhook_url, :string
    # HMAC key for x-bitblocks-signature; generated here, never accepted as input.
    field :webhook_secret, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc "Tag columns a filter may name."
  @spec tag_columns() :: [String.t()]
  def tag_columns, do: @tag_columns

  @doc false
  def changeset(projection, attrs) do
    projection
    |> cast(attrs, [:tenant, :name, :filter, :from_height, :status, :webhook_url])
    |> validate_required([:tenant, :name, :filter])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:from_height, greater_than_or_equal_to: 0)
    |> validate_change(:filter, fn :filter, filter -> filter_errors(filter) end)
    |> validate_change(:webhook_url, fn :webhook_url, url -> webhook_url_errors(url) end)
    |> put_definition_hash()
    |> put_webhook_secret()
    |> unique_constraint([:tenant, :name])
  end

  # Operator-registered for now (CLI). Before tenants self-register (#29 step
  # 5), delivery must also resolve the host and refuse private addresses, or a
  # tenant could point Bitblocks at its own network (SSRF).
  defp webhook_url_errors(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["https", "http"] and host not in [nil, ""] ->
        []

      _ ->
        [webhook_url: "must be an http(s) URL"]
    end
  end

  defp put_webhook_secret(changeset) do
    if get_field(changeset, :webhook_url) && is_nil(get_field(changeset, :webhook_secret)),
      do:
        put_change(
          changeset,
          :webhook_secret,
          Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        ),
      else: changeset
  end

  defp filter_errors(filter) when map_size(filter) == 0,
    do: [filter: "must name at least one tag column"]

  defp filter_errors(filter) do
    Enum.flat_map(filter, fn
      {column, _} when column not in @tag_columns ->
        [filter: "unknown tag column #{inspect(column)}"]

      {column, [_ | _] = values} ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: [],
          else: [filter: "#{column} values must be non-empty strings"]

      {column, _} ->
        [filter: "#{column} must be a non-empty list"]
    end)
  end

  defp put_definition_hash(%{valid?: true} = changeset) do
    case get_change(changeset, :filter) do
      nil -> changeset
      filter -> put_change(changeset, :definition_hash, definition_hash(filter))
    end
  end

  defp put_definition_hash(changeset), do: changeset

  @doc """
  sha256 of the canonical filter JSON: columns sorted, values sorted and
  deduplicated (a filter is a set of required tags, so order carries no meaning).
  """
  @spec definition_hash(map()) :: String.t()
  def definition_hash(filter) do
    canonical =
      filter
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {column, values} -> [column, values |> Enum.uniq() |> Enum.sort()] end)

    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end
end
