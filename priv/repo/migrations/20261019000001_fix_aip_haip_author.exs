defmodule Bitblocks.Repo.Migrations.FixAipHaipAuthor do
  use Ecto.Migration

  # seed_builtin_protocols/0 skips existing rows, so already-seeded AIP and
  # HAIP rows keep the old "unwriter" credit. AIP is Attila Aros (attilaaf);
  # HAIP's author is unverified, so it is cleared rather than guessed.
  def up do
    execute("""
    UPDATE protocols SET author = 'attilaaf'
    WHERE address = '15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva' AND author = 'unwriter'
    """)

    execute("""
    UPDATE protocols SET author = NULL
    WHERE address = '1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3' AND author = 'unwriter'
    """)
  end

  def down, do: :ok
end
