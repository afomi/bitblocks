defmodule Bitblocks.Annotations.Annotation do
  @moduledoc """
  One event placed on the chain: a fork, an upgrade, a halving, a minting, a
  milestone or a real-world event. See `Bitblocks.Annotations`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(fork upgrade halving milestone mint world note)

  @derive {Jason.Encoder,
           only: [
             :id,
             :kind,
             :title,
             :body,
             :source_url,
             :height,
             :txid,
             :occurred_at,
             :resolved_height,
             :resolved_by,
             :inserted_at,
             :updated_at
           ]}

  schema "chain_annotations" do
    field :kind, :string
    field :title, :string
    field :body, :string
    field :source_url, :string
    field :height, :integer
    field :txid, :string
    field :occurred_at, :utc_datetime
    field :resolved_height, :integer
    field :resolved_by, :string

    timestamps(type: :utc_datetime)
  end

  @doc "The kinds an annotation may have, in the order the UI lists them."
  def kinds, do: @kinds

  @doc "What an admin may set. `resolved_height` and `resolved_by` are derived."
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [:kind, :title, :body, :source_url, :height, :txid, :occurred_at])
    |> update_change(:txid, &normalize_txid/1)
    |> update_change(:title, &String.trim/1)
    |> validate_required([:kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, max: 200)
    |> validate_number(:height, greater_than_or_equal_to: 0)
    |> validate_format(:txid, ~r/\A[0-9a-f]{64}\z/, message: "must be 64 hex characters")
    |> validate_format(:source_url, ~r{\Ahttps?://},
      message: "must start with http:// or https://"
    )
    |> validate_anchor()
  end

  @doc "Sets where the annotation draws (see `Bitblocks.Annotations.resolve/1`)."
  def resolution_changeset(annotation, resolved_height, resolved_by) do
    change(annotation, resolved_height: resolved_height, resolved_by: resolved_by)
  end

  defp normalize_txid(nil), do: nil
  defp normalize_txid(txid), do: txid |> String.trim() |> String.downcase()

  defp validate_anchor(changeset) do
    if Enum.all?([:height, :txid, :occurred_at], &is_nil(get_field(changeset, &1))) do
      add_error(changeset, :height, "set a height, a txid or a date")
    else
      changeset
    end
  end
end
