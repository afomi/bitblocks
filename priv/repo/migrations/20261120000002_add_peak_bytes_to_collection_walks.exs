defmodule Bitblocks.Repo.Migrations.AddPeakBytesToCollectionWalks do
  use Ecto.Migration

  # The high-water mark of a collection's jobs (#47), so a change to the walk
  # can be measured on real data.
  #
  # peak_bytes       — the most the walk's process held above where it started:
  #                    its heap and the binaries it references.
  # trace_peak_bytes — the same for the largest trace batch since this walk.
  def change do
    alter table(:collection_walks) do
      add(:peak_bytes, :bigint)
      add(:trace_peak_bytes, :bigint)
    end
  end
end
