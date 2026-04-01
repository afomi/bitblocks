defmodule Bitblocks.ShapeLayerTest do
  use ExUnit.Case, async: true

  alias Bitblocks.ShapeLayer

  @polygon %{
    "type" => "Polygon",
    "coordinates" => [
      [[-122.4, 37.8], [-122.4, 37.7], [-122.3, 37.7], [-122.3, 37.8], [-122.4, 37.8]]
    ]
  }

  @point %{
    "type" => "Point",
    "coordinates" => [-122.4194, 37.7749]
  }

  @line %{
    "type" => "LineString",
    "coordinates" => [[-122.4, 37.8], [-122.3, 37.7]]
  }

  describe "new/2" do
    test "creates shape layer from polygon with bounds and center" do
      {:ok, shape} = ShapeLayer.new(@polygon, description: "SF block")

      assert shape.description == "SF block"
      assert shape.bounds.min_lon == -122.4
      assert shape.bounds.max_lon == -122.3
      assert shape.bounds.min_lat == 37.7
      assert shape.bounds.max_lat == 37.8
      assert shape.center.lon == -122.35
      assert shape.center.lat == 37.75
      assert shape.geometry == @polygon
      assert %DateTime{} = shape.created_at
    end

    test "creates shape layer from point" do
      {:ok, shape} = ShapeLayer.new(@point)

      assert shape.center.lon == -122.4194
      assert shape.center.lat == 37.7749
    end

    test "creates shape layer from line string" do
      {:ok, shape} = ShapeLayer.new(@line)

      assert shape.bounds.min_lon == -122.4
      assert shape.bounds.max_lon == -122.3
    end

    test "accepts block_height and properties" do
      {:ok, shape} =
        ShapeLayer.new(@polygon,
          block_height: 100,
          properties: %{"color" => "red"}
        )

      assert shape.block_height == 100
      assert shape.properties["color"] == "red"
    end

    test "rejects invalid geometry" do
      assert {:error, _} = ShapeLayer.new(%{"type" => "Invalid"})
      assert {:error, _} = ShapeLayer.new(%{})
    end
  end

  describe "to_geojson/1" do
    test "converts shape layer to GeoJSON Feature" do
      {:ok, shape} = ShapeLayer.new(@polygon, description: "test", block_height: 42)
      geojson = ShapeLayer.to_geojson(shape)

      assert geojson["type"] == "Feature"
      assert geojson["geometry"] == @polygon
      assert geojson["properties"]["description"] == "test"
      assert geojson["properties"]["block_height"] == 42
      assert %{} = geojson["properties"]["bounds"]
      assert %{} = geojson["properties"]["center"]
      assert is_binary(geojson["properties"]["created_at"])
    end
  end

  describe "from_geojson/1" do
    test "round-trips through GeoJSON" do
      {:ok, original} = ShapeLayer.new(@polygon, description: "roundtrip", block_height: 50)
      geojson = ShapeLayer.to_geojson(original)
      {:ok, restored} = ShapeLayer.from_geojson(geojson)

      assert restored.description == "roundtrip"
      assert restored.block_height == 50
      assert restored.geometry == @polygon
      assert restored.bounds == original.bounds
      assert restored.center == original.center
    end

    test "rejects non-Feature input" do
      assert {:error, _} = ShapeLayer.from_geojson(%{"type" => "FeatureCollection"})
    end
  end
end
