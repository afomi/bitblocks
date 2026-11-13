defmodule BitblocksWeb.Api.TypeController do
  @moduledoc """
  Read API for transaction types, the same definitions `/types` renders.

      GET /api/v1/types       every type with its tx count, without examples
      GET /api/v1/types/:id   one type, with its latest examples from the index
      GET /api/v1/types/export      the research export (#51): types by
                                    10,000-block bucket, with coverage and provenance
      GET /api/v1/types/export.csv  the same rows as CSV

  Each type carries `url`, its page on this site (the configured host, such as
  https://bitblocks.app/types/bsv-21), so other tools can link to it.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.{Counts, Examples, Export}

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

  @doc """
  The research export (`Bitblocks.TxTypes.Export`): every type's first
  appearance and txs per 10,000-block bucket over the range verified complete
  and typed, with the versions, definitions hash and runs behind them.
  """
  def export(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(Export.dataset())
  end

  @doc """
  The export's rows as CSV. The range and provenance ride in headers, since a
  CSV has nowhere else to put them; the JSON export carries them in full.
  """
  def export_csv(conn, _params) do
    summary = Counts.get()
    data = Export.dataset(summary)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header(
      "content-disposition",
      ~s(inline; filename="bitblocks-tx-types-by-height.csv")
    )
    |> put_resp_header("x-through-height", to_string(data.coverage.through_height))
    |> put_resp_header("x-type-counts-version", to_string(data.provenance.versions.type_counts))
    |> put_resp_header("x-definitions-sha256", data.provenance.definitions_sha256)
    |> put_resp_header("x-rows-sha256", data.rows_sha256)
    |> send_resp(200, Export.csv(summary))
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
      counts: type_counts_json(Counts.count(summary, type.id), Counts.adoption(summary, type.id))
    }
  end

  defp type_counts_json(nil, _adoption), do: nil

  defp type_counts_json(%{txs: txs, first_height: h}, adoption) do
    %{
      txs: txs,
      first_seen_height: h,
      first_seen_txid: adoption && adoption.first_txid,
      first_seen_time: adoption && adoption.first_time,
      per_10000_blocks: (adoption && adoption.per_10000_blocks) || []
    }
  end

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
