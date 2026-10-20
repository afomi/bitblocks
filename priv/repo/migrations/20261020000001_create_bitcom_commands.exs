defmodule Bitblocks.Repo.Migrations.CreateBitcomCommands do
  use Ecto.Migration

  # Append-only log of every Bitcom `$` command seen on-chain (unwriter's
  # Bitcom: useradd, echo … to, cat … to, route enable, route add). The log is
  # the canonical record; a namespace's files and routes are views over it.
  #
  # actor     — the P2PKH address that funded the tx (first input). Bitcom's
  #             only authentication: a command speaks for the address that paid.
  # namespace — the Bitcom address the command applies to. The actor's own for
  #             useradd/echo/cat/route enable; the named admin for route add.
  # valid     — false (with reason) when the command is malformed or the actor
  #             isn't allowed to issue it. Kept, not dropped, so the log is
  #             complete and the rejection is inspectable.
  def change do
    create table(:bitcom_commands) do
      add(:txid, :string, null: false)
      add(:output_index, :integer, null: false)
      add(:block_height, :integer)
      add(:actor, :string)
      add(:namespace, :string)
      add(:command, :string, null: false)
      # Pushes after the command word, as text (non-UTF-8 pushes as "0x<hex>").
      add(:args, {:array, :text}, null: false, default: [])
      # echo/cat target filename.
      add(:file, :string)
      # echo payload.
      add(:content, :text)
      # cat source: bit://<address>/<txid>.
      add(:locator, :string)
      # route enable / route add matcher (route-parser syntax).
      add(:route_matcher, :string)
      # route add endpoint template, e.g. https://host/${tx}.
      add(:endpoint, :text)
      add(:valid, :boolean, null: false, default: false)
      add(:reason, :string)

      timestamps()
    end

    create(unique_index(:bitcom_commands, [:txid, :output_index]))
    create(index(:bitcom_commands, [:namespace, :command]))
    create(index(:bitcom_commands, [:actor]))
  end
end
