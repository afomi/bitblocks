defmodule Bitblocks.Repo.Migrations.BigIntBlockSize do
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      modify :size, :bigint
    end
  end
end
