defmodule Bitblocks.ShapeLayer do
  @moduledoc """
  Shape Layer NFT — GeoJSON-based on-chain assets.

  A shape layer contains a GeoJSON geometry object with metadata
  suitable for on-chain storage as an NFT.
  Each shape layer has bounds, center, description, and timestamps.
  """

  @type t :: %__MODULE__{
          geometry: map(),
          properties: map(),
          bounds: map(),
          center: map(),
          description: String.t(),
          created_at: DateTime.t(),
          block_height: integer() | nil
        }

  defstruct [
    :geometry,
    :properties,
    :bounds,
    :center,
    :description,
    :created_at,
    :block_height
  ]

  @doc """
  Creates a new shape layer from a GeoJSON geometry and optional metadata.

  ## Examples

      iex> geometry = %{"type" => "Polygon", "coordinates" => [[[-122.4, 37.8], [-122.4, 37.7], [-122.3, 37.7], [-122.3, 37.8], [-122.4, 37.8]]]}
      iex> {:ok, shape} = Bitblocks.ShapeLayer.new(geometry, description: "San Francisco block")
      iex> shape.center
      %{lon: -122.35, lat: 37.75}
  """
  def new(geometry, opts \\ []) do
    with :ok <- validate_geometry(geometry) do
      coords = extract_coordinates(geometry)
      bounds = compute_bounds(coords)
      center = compute_center(bounds)

      shape = %__MODULE__{
        geometry: geometry,
        properties: Keyword.get(opts, :properties, %{}),
        bounds: bounds,
        center: center,
        description: Keyword.get(opts, :description, ""),
        created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
        block_height: Keyword.get(opts, :block_height)
      }

      {:ok, shape}
    end
  end

  @doc """
  Converts a shape layer to a GeoJSON Feature for on-chain storage.
  """
  def to_geojson(%__MODULE__{} = shape) do
    %{
      "type" => "Feature",
      "geometry" => shape.geometry,
      "properties" => Map.merge(shape.properties, %{
        "description" => shape.description,
        "bounds" => shape.bounds,
        "center" => shape.center,
        "created_at" => DateTime.to_iso8601(shape.created_at),
        "block_height" => shape.block_height
      })
    }
  end

  @doc """
  Parses a GeoJSON Feature back into a ShapeLayer struct.
  """
  def from_geojson(%{"type" => "Feature", "geometry" => geometry, "properties" => props}) do
    created_at =
      case Map.get(props, "created_at") do
        nil -> DateTime.utc_now()
        dt_string -> DateTime.from_iso8601(dt_string) |> elem(1)
      end

    new(geometry,
      description: Map.get(props, "description", ""),
      properties: Map.drop(props, ["description", "bounds", "center", "created_at", "block_height"]),
      created_at: created_at,
      block_height: Map.get(props, "block_height")
    )
  end

  def from_geojson(_), do: {:error, "Invalid GeoJSON Feature"}

  # Validation

  defp validate_geometry(%{"type" => type, "coordinates" => coords})
       when type in ["Point", "LineString", "Polygon", "MultiPoint", "MultiLineString", "MultiPolygon"] and
              is_list(coords) do
    :ok
  end

  defp validate_geometry(_), do: {:error, "Invalid GeoJSON geometry: must have type and coordinates"}

  # Coordinate extraction (flattens nested coordinate arrays to [lon, lat] pairs)

  defp extract_coordinates(%{"type" => "Point", "coordinates" => coords}) do
    [coords]
  end

  defp extract_coordinates(%{"type" => "LineString", "coordinates" => coords}) do
    coords
  end

  defp extract_coordinates(%{"type" => "Polygon", "coordinates" => rings}) do
    Enum.flat_map(rings, & &1)
  end

  defp extract_coordinates(%{"type" => "MultiPoint", "coordinates" => coords}) do
    coords
  end

  defp extract_coordinates(%{"type" => "MultiLineString", "coordinates" => lines}) do
    Enum.flat_map(lines, & &1)
  end

  defp extract_coordinates(%{"type" => "MultiPolygon", "coordinates" => polygons}) do
    polygons |> Enum.flat_map(fn rings -> Enum.flat_map(rings, & &1) end)
  end

  # Bounds computation

  defp compute_bounds(coords) when length(coords) > 0 do
    {min_lon, max_lon} =
      coords
      |> Enum.map(&Enum.at(&1, 0))
      |> Enum.min_max()

    {min_lat, max_lat} =
      coords
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.min_max()

    %{
      min_lon: min_lon,
      min_lat: min_lat,
      max_lon: max_lon,
      max_lat: max_lat
    }
  end

  defp compute_bounds(_), do: %{min_lon: 0, min_lat: 0, max_lon: 0, max_lat: 0}

  # Center computation

  defp compute_center(%{min_lon: min_lon, min_lat: min_lat, max_lon: max_lon, max_lat: max_lat}) do
    %{
      lon: (min_lon + max_lon) / 2,
      lat: (min_lat + max_lat) / 2
    }
  end
end
