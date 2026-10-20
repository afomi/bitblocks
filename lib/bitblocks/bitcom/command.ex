defmodule Bitblocks.Bitcom.Command do
  @moduledoc """
  One Bitcom `$` command from one OP_RETURN output. See `Bitblocks.Bitcom`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "bitcom_commands" do
    field :txid, :string
    field :output_index, :integer
    field :block_height, :integer
    # Address that funded the tx (first input); the command's author.
    field :actor, :string
    # Address the command applies to.
    field :namespace, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :file, :string
    field :content, :string
    field :locator, :string
    field :route_matcher, :string
    field :endpoint, :string
    field :valid, :boolean, default: false
    field :reason, :string

    timestamps()
  end

  @fields [
    :txid,
    :output_index,
    :block_height,
    :actor,
    :namespace,
    :command,
    :args,
    :file,
    :content,
    :locator,
    :route_matcher,
    :endpoint,
    :valid,
    :reason
  ]

  @doc false
  def changeset(command, attrs) do
    command
    |> cast(attrs, @fields)
    |> validate_required([:txid, :output_index, :command])
    |> unique_constraint([:txid, :output_index])
  end
end
