defmodule Bitblocks.Repo.Migrations.PointMetanetDocsAtNchainPaper do
  use Ecto.Migration

  # metanet.planaria.network is gone; nChain's technical summary is the source
  # the /types/metanet page adapts (CC BY-SA). Only the seeded value changes,
  # so a URL someone set by hand is left alone.
  @old "https://metanet.planaria.network/"
  @new "https://nchain.com/wp-content/uploads/2022/09/The-Metanet-Technical-Summary-v1.0.pdf"

  def up do
    execute("""
    UPDATE protocols SET documentation_url = '#{@new}', updated_at = now()
    WHERE address = 'meta' AND documentation_url = '#{@old}'
    """)
  end

  def down do
    execute("""
    UPDATE protocols SET documentation_url = '#{@old}', updated_at = now()
    WHERE address = 'meta' AND documentation_url = '#{@new}'
    """)
  end
end
