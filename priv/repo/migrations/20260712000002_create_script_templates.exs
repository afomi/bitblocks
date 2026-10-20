defmodule Bitblocks.Repo.Migrations.CreateScriptTemplates do
  use Ecto.Migration

  # Registry of reusable script templates (terms' Script Contract Library and
  # any other contract-shaped script). A template is a script SHAPE — opcodes
  # fixed, push-data slots variable — identified by its template_hash, the
  # same hash TransactionParser.analyze/1 stamps into
  # transactions.output_template_hashes. Registering a template makes every
  # past and future on-chain instance discoverable by one GIN lookup.
  def change do
    create table(:script_templates) do
      # Human-readable template name, unique — e.g. "escrow-2of3-v1".
      add(:name, :string, null: false)

      # sha256 (lowercase hex) of the opcode skeleton; see
      # Bitblocks.Script.template_hash/1. The join key to
      # transactions.output_template_hashes.
      add(:template_hash, :string, null: false)

      # Canonical ASM of the template body with placeholder push slots —
      # documentation of the shape, not used for matching.
      add(:body_asm, :text)

      # Typed argument spec for the push-data slots, in declaration order:
      # %{"args" => [%{"name" => "seller_pkh", "type" => "hash160"}, ...]}.
      # Types are advisory (rendering/validation hints), not consensus rules.
      add(:args, :map, default: %{}, null: false)

      # Where the template came from — e.g. "terms", "manual", a URL.
      add(:source, :string)

      timestamps()
    end

    create(unique_index(:script_templates, [:template_hash]))
    create(unique_index(:script_templates, [:name]))
  end
end
