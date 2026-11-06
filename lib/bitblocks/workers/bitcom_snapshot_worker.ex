defmodule Bitblocks.Workers.BitcomSnapshotWorker do
  @moduledoc """
  Daily: writes a new Bitcom registry snapshot if the registry changed
  (`Bitblocks.Bitcom.Snapshots`, #21). Reads `bitcom_commands` and `protocols`
  only, so it never touches `transactions`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3_600]

  @impl Oban.Worker
  def perform(_job) do
    case Bitblocks.Bitcom.Snapshots.take() do
      {:ok, _result, _snapshot} -> :ok
      {:error, changeset} -> {:error, inspect(changeset.errors)}
    end
  end
end
