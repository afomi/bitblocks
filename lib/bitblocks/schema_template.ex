defmodule Bitblocks.SchemaTemplate do
  @moduledoc """
  Schema.org transaction templates for Bitcoin SV OP_RETURN payloads.

  Generates structured data conforming to schema.org types that can be
  stored on-chain in OP_RETURN outputs. Supports event sourcing by
  aggregating a sequence of schema.org transactions into current state.
  """

  @schema_context "https://schema.org"

  @doc """
  Generates an Event schema.org payload.

  ## Options

    * `:name` - Event name (required)
    * `:start_date` - ISO8601 start date (required)
    * `:end_date` - ISO8601 end date
    * `:location` - Location name or address
    * `:description` - Event description
    * `:organizer` - Organizer name
    * `:url` - Event URL
  """
  def event(opts) do
    base = %{
      "@context" => @schema_context,
      "@type" => "Event",
      "name" => Keyword.fetch!(opts, :name),
      "startDate" => Keyword.fetch!(opts, :start_date)
    }

    base
    |> put_opt(:end_date, "endDate", opts)
    |> put_opt(:location, "location", opts)
    |> put_opt(:description, "description", opts)
    |> put_opt(:organizer, "organizer", opts)
    |> put_opt(:url, "url", opts)
  end

  @doc """
  Generates a Product schema.org payload.

  ## Options

    * `:name` - Product name (required)
    * `:description` - Product description
    * `:price` - Price amount
    * `:currency` - Price currency (default: "BSV")
    * `:sku` - Product SKU
    * `:brand` - Brand name
    * `:image` - Image URL
  """
  def product(opts) do
    base = %{
      "@context" => @schema_context,
      "@type" => "Product",
      "name" => Keyword.fetch!(opts, :name)
    }

    base =
      case {Keyword.get(opts, :price), Keyword.get(opts, :currency, "BSV")} do
        {nil, _} -> base
        {price, currency} ->
          Map.put(base, "offers", %{
            "@type" => "Offer",
            "price" => price,
            "priceCurrency" => currency
          })
      end

    base
    |> put_opt(:description, "description", opts)
    |> put_opt(:sku, "sku", opts)
    |> put_opt(:brand, "brand", opts)
    |> put_opt(:image, "image", opts)
  end

  @doc """
  Generates a Person schema.org payload.

  ## Options

    * `:name` - Full name (required)
    * `:email` - Email address
    * `:url` - Personal URL
    * `:job_title` - Job title
    * `:works_for` - Organization name
    * `:image` - Photo URL
  """
  def person(opts) do
    base = %{
      "@context" => @schema_context,
      "@type" => "Person",
      "name" => Keyword.fetch!(opts, :name)
    }

    base
    |> put_opt(:email, "email", opts)
    |> put_opt(:url, "url", opts)
    |> put_opt(:job_title, "jobTitle", opts)
    |> put_opt(:works_for, "worksFor", opts)
    |> put_opt(:image, "image", opts)
  end

  @doc """
  Converts a schema.org payload to an OP_RETURN-ready JSON string.
  """
  def to_op_return(schema_map) do
    Jason.encode!(schema_map)
  end

  @doc """
  Parses an OP_RETURN JSON string back into a schema.org map.
  Returns {:ok, map} or {:error, reason}.
  """
  def from_op_return(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"@type" => _type} = map} -> {:ok, map}
      {:ok, _} -> {:error, "Missing @type field"}
      error -> error
    end
  end

  @doc """
  Aggregates a sequence of schema.org event-sourced transactions into current state.

  Each event is a map with an `"action"` field:
  - `"create"` — sets initial state
  - `"update"` — merges fields into existing state
  - `"delete"` — marks entity as deleted

  ## Examples

      iex> events = [
      ...>   %{"action" => "create", "data" => %{"@type" => "Person", "name" => "Alice"}},
      ...>   %{"action" => "update", "data" => %{"email" => "alice@example.com"}},
      ...> ]
      iex> Bitblocks.SchemaTemplate.aggregate(events)
      {:ok, %{"@type" => "Person", "name" => "Alice", "email" => "alice@example.com"}}
  """
  def aggregate(events) when is_list(events) do
    result =
      Enum.reduce_while(events, nil, fn event, state ->
        case Map.get(event, "action") do
          "create" ->
            {:cont, Map.get(event, "data", %{})}

          "update" ->
            if state do
              {:cont, Map.merge(state, Map.get(event, "data", %{}))}
            else
              {:halt, {:error, "Update without prior create"}}
            end

          "delete" ->
            {:halt, {:deleted, state}}

          action ->
            {:halt, {:error, "Unknown action: #{inspect(action)}"}}
        end
      end)

    case result do
      {:error, reason} -> {:error, reason}
      {:deleted, _state} -> {:ok, :deleted}
      nil -> {:error, "No events"}
      state -> {:ok, state}
    end
  end

  defp put_opt(map, key, json_key, opts) do
    case Keyword.get(opts, key) do
      nil -> map
      val -> Map.put(map, json_key, val)
    end
  end
end
