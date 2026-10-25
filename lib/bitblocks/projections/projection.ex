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
  @statuses ~w(backfilling ready paused)

  @type t :: %__MODULE__{}

  schema "projections" do
    field :tenant, :string
    field :name, :string
    # Tag column => values; see the migration for the matching rule.
    field :filter, :map
    field :definition_hash, :string
    field :status, :string, default: "backfilling"

    timestamps(type: :utc_datetime)
  end

  @doc "Tag columns a filter may name."
  @spec tag_columns() :: [String.t()]
  def tag_columns, do: @tag_columns

  @doc false
  def changeset(projection, attrs) do
    projection
    |> cast(attrs, [:tenant, :name, :filter, :status])
    |> validate_required([:tenant, :name, :filter])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:filter, fn :filter, filter -> filter_errors(filter) end)
    |> put_definition_hash()
    |> unique_constraint([:tenant, :name])
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
