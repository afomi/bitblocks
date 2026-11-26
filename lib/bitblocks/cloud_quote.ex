defmodule Bitblocks.CloudQuote do
  @moduledoc """
  The quote request for cloud services on `/pricing#cloud`
  (https://github.com/afomi/bitblocks/issues/113): a buyer describes a filter
  the way the projection API takes it (`Bitblocks.Projections.Projection`),
  and sees a bounded estimate of what it would hold today.

  No price is set, and nothing is provisioned or billed here: the request
  goes out by email, with the spec and the estimate filled in.

  The estimate is the projection's own compiled query (`Projections.query/1`),
  limited to blocks `from_height..complete_through`, counted with a cap
  (`LIMIT cap + 1` inside a count) under a short `statement_timeout`. So it
  never scans `transactions` unbounded, and needs no new index: a filter
  names at least one GIN-indexed tag column (`Projection.indexed_columns/0`),
  the narrowing columns only filter its rows, and the command log has its own
  indexes.
  """

  import Ecto.Query

  alias Bitblocks.ChainScrubber
  alias Bitblocks.Projections
  alias Bitblocks.Projections.Projection
  alias Bitblocks.Repo

  @count_cap 10_000
  @timeout_ms 2_000
  @max_values 20
  @max_value_length 128

  @services [
    %{
      id: "projection",
      label: "Managed projection",
      delivery: "hydrate and follow over the projection API"
    },
    %{
      id: "database",
      label: "Filtered database",
      delivery: "a Postgres database we host and keep current"
    },
    %{
      id: "instance",
      label: "Dedicated instance",
      delivery: "a Bitblocks instance of your own"
    }
  ]

  @columns [
    %{
      column: "output_addresses",
      label: "Paid-to addresses",
      hint: "A tx matches when one of its outputs pays the address."
    },
    %{
      column: "protocols",
      label: "Protocols",
      hint: "A protocol prefix or MAP app the tx carries, such as MAP, B or AIP."
    },
    %{
      column: "output_script_hashes",
      label: "Script hashes",
      hint:
        "The sha256 of an output's locking script, as hex. It narrows another column's matches; it can't be the only one."
    },
    %{
      column: "output_template_hashes",
      label: "Template hashes",
      hint: "A script template's hash, as /api/v1/script/templates lists them."
    },
    %{
      column: "aip_signers",
      label: "AIP signers",
      hint:
        "An address that signed the tx's data with AIP. It narrows another column's matches; it can't be the only one."
    }
  ]

  @base58 ~r/\A[1-9A-HJ-NP-Za-km-z]{25,35}\z/

  @type spec :: %{
          service: String.t(),
          source: String.t(),
          filter: %{optional(String.t()) => [String.t()]},
          namespace: String.t() | nil,
          from_height: non_neg_integer(),
          definition_hash: String.t() | nil
        }

  @doc "The three cloud services, each with its label and how it's delivered."
  def services, do: @services

  @doc "The service with this id, or the managed projection."
  def service(id), do: Enum.find(@services, &(&1.id == id)) || hd(@services)

  @doc "The tag columns a filter may name, as the form shows them."
  def columns do
    # Kept in step with what the projection API accepts.
    tag_columns = Projection.tag_columns()
    Enum.filter(@columns, &(&1.column in tag_columns))
  end

  @doc "The most matching rows the estimate counts before it says \"more than\"."
  def count_cap, do: @count_cap

  @doc "The most values one column takes in the form."
  def max_values, do: @max_values

  @doc "The form's starting values: a managed projection over transactions, from block 0."
  def default_params do
    %{
      "service" => "projection",
      "source" => "transactions",
      "from_height" => "0",
      "namespace" => "",
      "filter" => Map.new(columns(), &{&1.column, ""})
    }
  end

  @doc """
  Reads the form into a spec, or the reasons it can't be one.

  Values in a column are split on commas, spaces and new lines, trimmed and
  deduplicated. The filter is checked by `Projection.changeset/2`, so what
  passes here is what the projection API takes, and it carries the same
  `definition_hash`.
  """
  @spec parse(map()) :: {:ok, spec()} | {:error, [String.t()]}
  def parse(params) when is_map(params) do
    service = service(params["service"]).id
    source = if params["source"] == "bitcom_commands", do: "bitcom_commands", else: "transactions"

    filter =
      if source == "transactions",
        do: params |> Map.get("filter", %{}) |> parse_filter(),
        else: %{}

    errors =
      []
      |> check_values(params, source)
      |> check_namespace(params, source)
      |> check_from(params)
      |> check_filter(service, source, filter)

    if errors == [] do
      namespace = if source == "bitcom_commands", do: blank_to_nil(params["namespace"])

      {:ok,
       %{
         service: service,
         source: source,
         filter: filter,
         namespace: namespace,
         from_height: parse_from(params["from_height"]),
         definition_hash: definition_hash(service, source, filter)
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc "The filter as JSON, as `POST`ed to a projection: columns in order."
  @spec filter_json(spec()) :: String.t()
  def filter_json(%{filter: filter}) do
    filter
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  @doc """
  What the spec would hold today, over blocks `from_height..through`, where
  `through` is `complete_through`: every block to it is complete.

  Returns `{:ok, %{count, capped, cap, from, through, unit}}`, where `count`
  stops at the cap and `capped` says there are more; or `{:error, reason}`:
  `:not_held` (no complete block in the range), `:whole_index` (a dedicated
  instance with no filter), `:timeout` or `:unavailable`.

  Options: `:cap` (#{@count_cap}), `:timeout_ms` (#{@timeout_ms}).
  """
  @spec estimate(spec(), integer() | nil, keyword()) :: {:ok, map()} | {:error, atom()}
  def estimate(spec, through, opts \\ [])

  def estimate(%{from_height: from}, through, _opts)
      when not is_integer(through) or through < from,
      do: {:error, :not_held}

  def estimate(%{source: "transactions", filter: filter}, _through, _opts)
      when map_size(filter) == 0,
      do: {:error, :whole_index}

  def estimate(spec, through, opts) do
    cap = Keyword.get(opts, :cap, @count_cap)
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)
    from = spec.from_height

    rows =
      %Projection{source: spec.source, filter: spec.filter}
      |> Projections.query()
      |> where([r], r.block_height >= ^from and r.block_height <= ^through)
      |> namespace(spec)
      |> select([r], %{id: r.id})
      |> limit(^(cap + 1))

    case ChainScrubber.with_statement_timeout(timeout, fn ->
           Repo.one(from(s in subquery(rows), select: count()))
         end) do
      {:ok, n} ->
        {:ok,
         %{
           count: min(n, cap),
           capped: n > cap,
           cap: cap,
           from: from,
           through: through,
           unit: if(spec.source == "bitcom_commands", do: "commands", else: "transactions")
         }}

      {:error, reason} when reason in [:timeout, :unavailable] ->
        {:error, reason}
    end
  end

  defp namespace(query, %{source: "bitcom_commands", namespace: ns}) when is_binary(ns),
    do: where(query, [c], c.namespace == ^ns)

  defp namespace(query, _spec), do: query

  @doc "Why there is no estimate, in plain words."
  def error_message(:not_held),
    do: "We don't hold a complete block in that range yet, so there is nothing to count."

  def error_message(:whole_index),
    do: "With no filter, a dedicated instance holds the whole index: we'll size it with you."

  def error_message(:timeout),
    do: "Too many to count quickly. We'll size it with you."

  def error_message(_), do: "The estimate is unavailable right now. Try again shortly."

  @doc """
  The mailto for a quote request: the address, a subject naming the service,
  and a body with the spec, the filter as JSON and the estimate, if one was
  made for this spec.
  """
  @spec mailto(String.t(), String.t() | nil, spec() | nil, map() | nil) :: String.t()
  def mailto(email, service_id, spec, estimate) do
    service = service(service_id)
    subject = "Cloud services quote: #{service.label}"
    body = Enum.join(body_lines(service, spec, estimate), "\n")

    "mailto:#{email}?" <> URI.encode_query(%{subject: subject, body: body}, :rfc3986)
  end

  defp body_lines(service, spec, estimate) do
    ["Service: #{service.label} (#{service.delivery})"] ++
      spec_lines(spec, estimate) ++
      ["", "History, lag and bandwidth we need:", ""]
  end

  defp spec_lines(nil, _estimate), do: ["Filter: not described yet"]

  defp spec_lines(spec, estimate) do
    ["Source: #{spec.source}"] ++
      source_lines(spec) ++
      [
        "From block: #{format_number(spec.from_height)}",
        "Estimate: #{estimate_line(estimate)}"
      ]
  end

  defp source_lines(%{source: "bitcom_commands"} = spec) do
    [
      "Filter: {} (a command projection serves the whole Bitcom command log)",
      "Namespace of interest: #{spec.namespace || "all"}"
    ]
  end

  defp source_lines(spec) do
    ["Filter (as the projection API takes it): #{filter_json(spec)}"] ++
      if spec.definition_hash, do: ["Definition hash: #{spec.definition_hash}"], else: []
  end

  @doc "The estimate in one line, as the page and the email say it."
  def estimate_line(nil), do: "not estimated"

  def estimate_line(%{} = e) do
    count = if e.capped, do: "more than #{format_number(e.cap)}", else: format_number(e.count)

    "#{count} #{e.unit} in blocks #{format_number(e.from)} to #{format_number(e.through)} " <>
      "(complete through #{format_number(e.through)}), an estimate"
  end

  # -- Parsing ---------------------------------------------------------------

  defp parse_filter(raw) when is_map(raw) do
    for %{column: column} <- columns(),
        values = split(Map.get(raw, column)),
        values != [],
        into: %{},
        do: {column, values}
  end

  defp parse_filter(_), do: %{}

  defp split(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp split(_), do: []

  defp check_values(errors, params, "transactions") do
    raw = if is_map(params["filter"]), do: params["filter"], else: %{}

    Enum.reduce(columns(), errors, fn %{column: column, label: label}, acc ->
      values = split(Map.get(raw, column))

      cond do
        length(values) > @max_values ->
          ["#{label}: at most #{@max_values} values." | acc]

        Enum.any?(values, &(String.length(&1) > @max_value_length)) ->
          ["#{label}: each value is at most #{@max_value_length} characters." | acc]

        true ->
          acc
      end
    end)
  end

  defp check_values(errors, _params, _source), do: errors

  defp check_namespace(errors, params, "bitcom_commands") do
    case blank_to_nil(params["namespace"]) do
      nil -> errors
      ns -> if ns =~ @base58, do: errors, else: ["Namespace: a Bitcom address." | errors]
    end
  end

  defp check_namespace(errors, _params, _source), do: errors

  defp check_from(errors, params) do
    if parse_from(params["from_height"]) == :error,
      do: ["From block: a whole number, 0 or more." | errors],
      else: errors
  end

  defp check_filter(errors, service, "transactions", filter) do
    cond do
      errors != [] ->
        errors

      filter == %{} and service == "instance" ->
        errors

      filter == %{} ->
        ["Name at least one value: an address, protocol, hash or signer." | errors]

      true ->
        changeset =
          Projection.changeset(%Projection{}, %{
            tenant: "quote",
            name: "quote",
            source: "transactions",
            filter: filter
          })

        if changeset.valid?,
          do: errors,
          else:
            Enum.map(changeset.errors, fn {_field, {msg, _}} -> "Filter: #{msg}." end) ++ errors
    end
  end

  defp check_filter(errors, _service, _source, _filter), do: errors

  defp definition_hash(_service, "transactions", filter) when map_size(filter) == 0, do: nil
  defp definition_hash(_service, source, filter), do: Projection.definition_hash(filter, source)

  defp parse_from(value) do
    case blank_to_nil(value) do
      nil ->
        0

      text ->
        case Integer.parse(String.replace(text, ",", "")) do
          {n, ""} when n >= 0 -> n
          _ -> :error
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  @doc false
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
