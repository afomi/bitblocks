defmodule Bitblocks.Repo.Migrations.BackfillTransactionCounts do
  use Ecto.Migration
  import Ecto.Query
  alias Bitblocks.Repo
  alias Bitblocks.Chain.Transaction

  def up do
    # Process transactions in batches to avoid memory issues
    batch_size = 1000

    # Get total count for progress tracking
    total = Repo.aggregate(Transaction, :count, :id)
    IO.puts("\nBackfilling input_count and output_count for #{total} transactions...")

    process_batch(0, batch_size, total, 0)

    IO.puts("\nBackfill complete!")
  end

  defp process_batch(offset, batch_size, total, processed) do
    # Fetch a batch of transactions that need updating
    transactions =
      from(t in Transaction,
        where: is_nil(t.input_count) or is_nil(t.output_count),
        limit: ^batch_size,
        offset: ^offset,
        select: [:id, :raw]
      )
      |> Repo.all()

    case transactions do
      [] ->
        # No more transactions to process
        :ok

      txs ->
        # Process each transaction in the batch
        Enum.each(txs, fn tx ->
          case decode_and_count(tx.raw) do
            {input_count, output_count} ->
              from(t in Transaction, where: t.id == ^tx.id)
              |> Repo.update_all(set: [input_count: input_count, output_count: output_count])

            :error ->
              # If decoding fails, set to 0
              from(t in Transaction, where: t.id == ^tx.id)
              |> Repo.update_all(set: [input_count: 0, output_count: 0])
          end
        end)

        new_processed = processed + length(txs)
        progress = Float.round(new_processed / total * 100, 1)
        IO.write("\rProgress: #{new_processed}/#{total} (#{progress}%)  ")

        # Process next batch
        process_batch(offset + batch_size, batch_size, total, new_processed)
    end
  end

  defp decode_and_count(raw_hex) when is_binary(raw_hex) do
    case BSV.Tx.from_binary(raw_hex, encoding: :hex) do
      {:ok, decoded_tx} ->
        {length(decoded_tx.inputs), length(decoded_tx.outputs)}

      {:error, _} ->
        :error
    end
  end

  defp decode_and_count(_), do: :error

  def down do
    # Reset the counts to nil if rolling back
    from(t in Transaction)
    |> Repo.update_all(set: [input_count: nil, output_count: nil])
  end
end
