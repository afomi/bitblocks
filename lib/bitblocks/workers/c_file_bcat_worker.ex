defmodule Bitblocks.Workers.CFileBcatWorker do
  @moduledoc """
  Assembles one BCat file and indexes it by the sha256 of the whole file
  (`Bitblocks.CFiles.index_bcat/3`,
  https://github.com/afomi/bitblocks/issues/155).

  The `index_c_files` step enqueues it for each stored tx tagged BCat, so
  the tx pipeline's insert never reads chunks: up to 256 of them and 32 MB,
  from our database or tx store, else WhatsOnChain as raw txs checked
  against their txids. It runs on `:derived` (concurrency 1), the lane
  that already holds work derived from stored rows, off the sync's slots.

  Unique on the head txid. A head already indexed is done. A head whose
  chunk source couldn't be asked just now (`:unavailable`) is retried with
  Oban's backoff, up to `max_attempts`; its miss is recorded on each try,
  so a head that never assembles stays unindexed with its reason. Any
  other reason (a chunk no source has, too large, no chunks) is recorded
  and not retried: a later backfill run tries the head again.
  """

  use Oban.Worker,
    queue: :derived,
    priority: 3,
    max_attempts: 5,
    unique: [period: 3600, fields: [:args], keys: [:txid]]

  import Ecto.Query

  alias Bitblocks.CFiles
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"txid" => txid}}) do
    # The head's stored row, not the args: a reorg may have moved or
    # removed it since the job was enqueued.
    stored =
      Repo.one(
        from(t in Transaction,
          where: t.txid == ^txid,
          select: %{block_height: t.block_height},
          limit: 1
        )
      )

    cond do
      is_nil(stored) ->
        {:cancel, :head_not_stored}

      CFiles.bcat_indexed?(txid) ->
        :ok

      true ->
        case CFiles.index_bcat(txid, stored.block_height) do
          {:ok, _row} -> :ok
          {:error, :unavailable} -> {:error, :unavailable}
          {:error, _reason} -> :ok
        end
    end
  end
end
