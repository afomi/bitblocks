defmodule Bitblocks.Projections.Projection do
  @moduledoc """
  A tenant's filter over the tag columns on `transactions`, or (source
  `bitcom_commands`, Tenant 3 of #29) the Bitcom registry's command log, whole.
  See `Bitblocks.Projections` and docs/MANAGED_SERVICES.md.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Bitblocks.Projections.WebhookTarget

  # Ingest-time tag columns, each GIN-indexed, so a containment filter on any
  # of them is an index lookup rather than a scan of `transactions`.
  @tag_columns ~w(output_addresses protocols output_script_hashes output_template_hashes aip_signers)
  @statuses ~w(active paused)
  # What a projection reads: txs by its tag filter, or the Bitcom command log
  # whole, whose filter is empty.
  @sources ~w(transactions bitcom_commands)

  @type t :: %__MODULE__{}

  schema "projections" do
    field :tenant, :string
    field :name, :string
    # transactions | bitcom_commands; part of the definition, so never changed.
    field :source, :string, default: "transactions"
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
    # Deliveries given up on since the webhook was set; see the migration.
    field :webhook_failures, :integer, default: 0
    field :webhook_failed_at, :utc_datetime
    field :webhook_failed_event, :string
    field :webhook_failed_status, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Tag columns a filter may name."
  @spec tag_columns() :: [String.t()]
  def tag_columns, do: @tag_columns

  @doc "Sources a projection may read."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc false
  def changeset(projection, attrs) do
    projection
    |> cast(attrs, [:tenant, :name, :source, :filter, :from_height, :status, :webhook_url])
    |> validate_inclusion(:source, @sources)
    |> default_filter()
    |> validate_required([:tenant, :name, :filter])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:from_height, greater_than_or_equal_to: 0)
    |> validate_filter()
    |> validate_change(:webhook_url, fn :webhook_url, url -> webhook_url_errors(url) end)
    |> validate_webhook_source()
    |> put_definition_hash()
    |> put_webhook_secret()
    |> unique_constraint([:tenant, :name])
  end

  # The command log is served whole, so its filter is empty and may be omitted.
  defp default_filter(changeset) do
    if get_field(changeset, :source) == "bitcom_commands" and
         is_nil(get_field(changeset, :filter)),
       do: put_change(changeset, :filter, %{}),
       else: changeset
  end

  defp validate_filter(changeset) do
    case get_field(changeset, :source) do
      "bitcom_commands" ->
        validate_change(changeset, :filter, fn :filter, filter ->
          if filter == %{},
            do: [],
            else: [filter: "must be empty for the bitcom_commands source"]
        end)

      _ ->
        validate_change(changeset, :filter, fn :filter, filter -> filter_errors(filter) end)
    end
  end

  # Webhooks deliver txs; a command projection follows over SSE.
  defp validate_webhook_source(changeset) do
    if get_field(changeset, :source) == "bitcom_commands" and get_field(changeset, :webhook_url),
      do: add_error(changeset, :webhook_url, "is not offered for the bitcom_commands source"),
      else: changeset
  end

  # Only a public host (SSRF); delivery checks again. See WebhookTarget.
  defp webhook_url_errors(url) do
    case WebhookTarget.check(url) do
      :ok -> []
      {:error, reason} -> [webhook_url: reason]
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
      nil ->
        changeset

      filter ->
        source = get_field(changeset, :source)
        put_change(changeset, :definition_hash, definition_hash(filter, source))
    end
  end

  defp put_definition_hash(changeset), do: changeset

  @doc """
  sha256 of the canonical filter JSON: columns sorted, values sorted and
  deduplicated (a filter is a set of required tags, so order carries no meaning).

  A source other than `transactions` is hashed with the source named,
  `{"filter":[…],"source":"…"}`, so it never shares a hash with a tx filter,
  and the hashes of tx projections stay what they were.
  """
  @spec definition_hash(map(), String.t()) :: String.t()
  def definition_hash(filter, source \\ "transactions") do
    canonical =
      filter
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {column, values} -> [column, values |> Enum.uniq() |> Enum.sort()] end)

    bytes =
      case source do
        "transactions" ->
          Jason.encode!(canonical)

        source ->
          ~s({"filter":#{Jason.encode!(canonical)},"source":#{Jason.encode!(source)}})
      end

    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
