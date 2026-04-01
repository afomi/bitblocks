defmodule Bitblocks.SchemaTemplateTest do
  use ExUnit.Case, async: true

  alias Bitblocks.SchemaTemplate

  describe "event/1" do
    test "generates Event schema with required fields" do
      result = SchemaTemplate.event(name: "BSV Meetup", start_date: "2026-04-01T18:00:00Z")

      assert result["@context"] == "https://schema.org"
      assert result["@type"] == "Event"
      assert result["name"] == "BSV Meetup"
      assert result["startDate"] == "2026-04-01T18:00:00Z"
    end

    test "includes optional fields" do
      result =
        SchemaTemplate.event(
          name: "Conference",
          start_date: "2026-05-01",
          end_date: "2026-05-03",
          location: "Portland, OR",
          description: "Annual BSV conference",
          organizer: "BSV Academy"
        )

      assert result["endDate"] == "2026-05-03"
      assert result["location"] == "Portland, OR"
      assert result["description"] == "Annual BSV conference"
      assert result["organizer"] == "BSV Academy"
    end
  end

  describe "product/1" do
    test "generates Product schema with price" do
      result =
        SchemaTemplate.product(
          name: "Bitcoin SV Node",
          price: "0.01",
          currency: "BSV",
          sku: "NODE-001"
        )

      assert result["@type"] == "Product"
      assert result["name"] == "Bitcoin SV Node"
      assert result["offers"]["price"] == "0.01"
      assert result["offers"]["priceCurrency"] == "BSV"
      assert result["sku"] == "NODE-001"
    end

    test "omits offers when no price" do
      result = SchemaTemplate.product(name: "Free Item")
      refute Map.has_key?(result, "offers")
    end
  end

  describe "person/1" do
    test "generates Person schema" do
      result =
        SchemaTemplate.person(
          name: "Satoshi Nakamoto",
          email: "satoshi@vistomail.com",
          url: "https://bitcoin.org",
          job_title: "Creator"
        )

      assert result["@type"] == "Person"
      assert result["name"] == "Satoshi Nakamoto"
      assert result["email"] == "satoshi@vistomail.com"
      assert result["jobTitle"] == "Creator"
    end
  end

  describe "to_op_return/1 and from_op_return/1" do
    test "round-trips through JSON" do
      original = SchemaTemplate.event(name: "Test", start_date: "2026-01-01")
      json = SchemaTemplate.to_op_return(original)
      {:ok, parsed} = SchemaTemplate.from_op_return(json)

      assert parsed["@type"] == "Event"
      assert parsed["name"] == "Test"
    end

    test "rejects non-schema JSON" do
      assert {:error, _} = SchemaTemplate.from_op_return(~s({"foo": "bar"}))
    end
  end

  describe "aggregate/1" do
    test "creates initial state from create event" do
      events = [
        %{"action" => "create", "data" => %{"@type" => "Person", "name" => "Alice"}}
      ]

      {:ok, state} = SchemaTemplate.aggregate(events)
      assert state["name"] == "Alice"
      assert state["@type"] == "Person"
    end

    test "applies updates to existing state" do
      events = [
        %{"action" => "create", "data" => %{"@type" => "Person", "name" => "Alice"}},
        %{"action" => "update", "data" => %{"email" => "alice@example.com"}},
        %{"action" => "update", "data" => %{"name" => "Alice Smith"}}
      ]

      {:ok, state} = SchemaTemplate.aggregate(events)
      assert state["name"] == "Alice Smith"
      assert state["email"] == "alice@example.com"
      assert state["@type"] == "Person"
    end

    test "handles delete action" do
      events = [
        %{"action" => "create", "data" => %{"@type" => "Product", "name" => "Widget"}},
        %{"action" => "delete"}
      ]

      {:ok, result} = SchemaTemplate.aggregate(events)
      assert result == :deleted
    end

    test "returns error for update without create" do
      events = [
        %{"action" => "update", "data" => %{"name" => "Orphan"}}
      ]

      assert {:error, _} = SchemaTemplate.aggregate(events)
    end

    test "returns error for empty event list" do
      assert {:error, _} = SchemaTemplate.aggregate([])
    end
  end
end
