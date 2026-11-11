defmodule Mix.Tasks.TxTypes.Propose do
  @moduledoc """
  Drafts a new transaction type from a real `custom` output (#51), into
  `priv/data/tx_types/types.json` and `chain_vectors.json` in this source
  tree, for a pull request. See `Bitblocks.TxTypes.Proposal`.

  Take the txid and template hash from a candidate
  (`Release.type_candidates/3`'s `example_txids` and `template_hash`):

      mix tx_types.propose push-add-equal --txid <txid> --template-hash <hash> \\
        --title "Push, add, equal" --short "Add" --summary "…" --spend "…" \\
        --description "…" --description "…" --history "…" \\
        --spec-label "…" --spec-url https://… --group conditions --related p2pkh

  Prints the draft; `--apply` writes it. Prose left out reads `TODO: …`, and
  the suite fails until a person writes it.

  Reads our database and tx store, then WhatsOnChain. It starts the repo
  only, never the sync.
  """

  use Mix.Task

  alias Bitblocks.TxTypes.Proposal

  @shortdoc "Draft a transaction type from a real custom output"

  @switches [
    txid: :string,
    template_hash: :string,
    title: :string,
    short: :string,
    summary: :string,
    spend: :string,
    spec_label: :string,
    spec_url: :string,
    group: :string,
    description: :keep,
    history: :keep,
    related: :keep,
    apply: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    with [id] <- rest,
         txid when is_binary(txid) <- opts[:txid],
         hash when is_binary(hash) <- opts[:template_hash] do
      start_repo()

      draft_opts =
        opts
        |> Keyword.take([:title, :short, :summary, :spend, :spec_label, :spec_url, :group])
        |> Keyword.merge(
          description: Keyword.get_values(opts, :description),
          history: Keyword.get_values(opts, :history),
          related: Keyword.get_values(opts, :related)
        )

      case Proposal.draft(id, txid, hash, draft_opts) do
        {:ok, draft} -> report(draft, opts[:apply])
        {:error, reason} -> Mix.raise("No draft: #{inspect(reason)}")
      end
    else
      _ -> Mix.raise("Usage: mix tx_types.propose <id> --txid <txid> --template-hash <hash>")
    end
  end

  defp start_repo do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    :ok = Bitblocks.HTTP.ensure_started()
    {:ok, _} = Bitblocks.Repo.start_link(pool_size: 2)
  end

  defp report(draft, apply?) do
    Mix.shell().info(Jason.encode!(draft.type, pretty: true))
    Mix.shell().info(Jason.encode!(draft.vector, pretty: true))

    if apply? do
      {:ok, paths} = Proposal.write(draft, File.cwd!())
      Mix.shell().info("Wrote #{Enum.join(paths, " and ")}.")

      Mix.shell().info("""
      Next: write any TODO prose, bump Bitblocks.TxTypes.Classifier's @version,
      run mix test, and open a pull request. Once merged and deployed, the
      tx_types backfill re-stamps past rows (docs/DERIVED_DATA.md).
      """)
    else
      Mix.shell().info("Dry run: add --apply to write it.")
    end
  end
end
