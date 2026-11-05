defmodule BitblocksWeb.Api.TypeController do
  @moduledoc """
  Read API for transaction types, the same definitions `/types` renders.

      GET /api/v1/types       every type with its tx count, without examples
      GET /api/v1/types/:id   one type, with its latest examples from the index

  Each type carries `url`, its page on this site (the configured host, such as
  https://bitblocks.app/types/bsv-21), so other tools can link to it.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.{Counts, Examples}

  @doc """
  Every type, in order, each with its tx count, and `counts`, the range of
  the chain the counts cover (`Bitblocks.TxTypes.Counts`, cached). Examples
  are only on the show endpoint.
  """
  def index(conn, _params) do
    summary = Counts.get()
    types = Enum.map(TxTypes.all(), &type_json(&1, summary))
    json(conn, %{data: types, count: length(types), counts: counts_json(summary)})
  end

  @doc "One type by id, with examples; 404 for an unknown id."
  def show(conn, %{"id" => id}) do
    case TxTypes.get(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Transaction type not found", id: id})

      type ->
        examples = Examples.for_type(type)

        json(conn, %{
          data:
            type
            |> type_json(Counts.get())
            |> Map.put(:examples, examples_json(type, examples))
        })
    end
  end

  defp type_json(type, summary) do
    %{
      id: type.id,
      title: type.title,
      short: type.short,
      group: type.group,
      summary: type.summary,
      description: type.description,
      history: type.history,
      spec: type.spec,
      pattern: type.pattern,
      spendable: type.spendable,
      spend: type.spend,
      related: type.related,
      concepts: Map.get(type, :concepts),
      attribution: Map.get(type, :attribution),
      url: url(~p"/types/#{type.id}"),
      api_url: url(~p"/api/v1/types/#{type.id}"),
      counts: type_counts_json(Counts.count(summary, type.id))
    }
  end

  defp type_counts_json(nil), do: nil
  defp type_counts_json(%{txs: txs, first_height: h}), do: %{txs: txs, first_seen_height: h}

  defp counts_json(summary) do
    %{
      status: summary.status,
      through_height: summary[:through_height],
      complete_through: summary[:complete_through],
      tip_height: summary[:tip],
      version: summary[:version],
      computed_at: summary[:computed_at],
      note: Counts.coverage_note(summary)
    }
  end

  defp examples_json(type, examples) do
    source = Map.get(type, :examples, %{})

    %{
      status: examples.status,
      kind: source[:kind],
      template_hashes: source[:template_hashes],
      protocols: source[:protocols],
      source: examples.source,
      count: examples.count,
      count_label: examples.count_label,
      transactions:
        Enum.map(examples.items, fn item ->
          %{
            txid: item.txid,
            block_height: item.block_height,
            note: item.note,
            url: url(~p"/transactions/#{item.txid}")
          }
        end)
    }
  end
end
