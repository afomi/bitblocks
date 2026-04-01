defmodule BitblocksWeb.ShapeLayerLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.ShapeLayer

  @sample_shapes [
    %{
      "type" => "Feature",
      "geometry" => %{
        "type" => "Polygon",
        "coordinates" => [
          [[-122.42, 37.79], [-122.42, 37.76], [-122.38, 37.76], [-122.38, 37.79], [-122.42, 37.79]]
        ]
      },
      "properties" => %{
        "description" => "San Francisco Financial District",
        "block_height" => 100,
        "created_at" => "2009-01-03T18:15:05Z"
      }
    },
    %{
      "type" => "Feature",
      "geometry" => %{
        "type" => "Point",
        "coordinates" => [-73.9857, 40.7484]
      },
      "properties" => %{
        "description" => "Empire State Building",
        "block_height" => 200,
        "created_at" => "2009-01-09T02:54:25Z"
      }
    },
    %{
      "type" => "Feature",
      "geometry" => %{
        "type" => "LineString",
        "coordinates" => [[-0.1278, 51.5074], [-0.0762, 51.5085], [-0.0236, 51.5030]]
      },
      "properties" => %{
        "description" => "London Thames Walk",
        "block_height" => 300,
        "created_at" => "2009-01-12T03:05:25Z"
      }
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    shapes =
      @sample_shapes
      |> Enum.map(fn geojson ->
        case ShapeLayer.from_geojson(geojson) do
          {:ok, shape} -> shape
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    socket =
      assign(socket,
        page_title: "Shape Layer NFTs",
        shapes: shapes,
        selected_index: 0
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("select_shape", %{"index" => index}, socket) do
    {:noreply, assign(socket, selected_index: String.to_integer(index))}
  end

  def selected_shape(assigns) do
    Enum.at(assigns.shapes, assigns.selected_index)
  end

  @doc """
  Renders GeoJSON geometry as an SVG path.
  Projects coordinates to a 400x300 SVG viewport.
  """
  def geometry_to_svg(shape) do
    coords = flatten_coords(shape.geometry)
    bounds = shape.bounds

    # Add padding
    pad = 0.01
    min_lon = bounds.min_lon - pad
    max_lon = bounds.max_lon + pad
    min_lat = bounds.min_lat - pad
    max_lat = bounds.max_lat + pad

    lon_range = max(max_lon - min_lon, 0.001)
    lat_range = max(max_lat - min_lat, 0.001)

    project = fn [lon, lat] ->
      x = (lon - min_lon) / lon_range * 380 + 10
      # SVG y is inverted
      y = (1.0 - (lat - min_lat) / lat_range) * 280 + 10
      {x, y}
    end

    case shape.geometry["type"] do
      "Point" ->
        [coord] = coords
        {cx, cy} = project.(coord)
        {:circle, cx, cy}

      "LineString" ->
        points =
          coords
          |> Enum.map(fn c -> project.(c) end)
          |> Enum.map(fn {x, y} -> "#{Float.round(x, 1)},#{Float.round(y, 1)}" end)
          |> Enum.join(" ")

        {:polyline, points}

      "Polygon" ->
        rings = shape.geometry["coordinates"]
        outer = hd(rings)

        points =
          outer
          |> Enum.map(fn c -> project.(c) end)
          |> Enum.map(fn {x, y} -> "#{Float.round(x, 1)},#{Float.round(y, 1)}" end)
          |> Enum.join(" ")

        {:polygon, points}

      _ ->
        {:unknown, ""}
    end
  end

  def project_center(shape) do
    bounds = shape.bounds
    pad = 0.01
    min_lon = bounds.min_lon - pad
    max_lon = bounds.max_lon + pad
    min_lat = bounds.min_lat - pad
    max_lat = bounds.max_lat + pad
    lon_range = max(max_lon - min_lon, 0.001)
    lat_range = max(max_lat - min_lat, 0.001)

    cx = (shape.center.lon - min_lon) / lon_range * 380 + 10
    cy = (1.0 - (shape.center.lat - min_lat) / lat_range) * 280 + 10
    {Float.round(cx, 1), Float.round(cy, 1)}
  end

  defp flatten_coords(%{"type" => "Point", "coordinates" => c}), do: [c]
  defp flatten_coords(%{"type" => "LineString", "coordinates" => c}), do: c
  defp flatten_coords(%{"type" => "Polygon", "coordinates" => rings}), do: Enum.flat_map(rings, & &1)
  defp flatten_coords(_), do: []
end
