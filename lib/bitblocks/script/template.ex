defmodule Bitblocks.Script.Template do
  @moduledoc """
  A registered script template — a script SHAPE (opcodes fixed, push-data
  slots variable) identified by its `template_hash`, the same hash
  `TransactionParser.analyze/1` stamps into `transactions.output_template_hashes`.

  Registering a template makes every past and future on-chain instance
  discoverable via `Chain.history_for_template_hash/1`. This is the read-side
  counterpart of terms' Script Contract Library: terms composes and signs
  template instances; bitblocks recognizes and indexes them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "script_templates" do
    field :name, :string
    field :template_hash, :string
    field :body_asm, :string
    # Typed argument spec for the push-data slots, in declaration order:
    # %{"args" => [%{"name" => "seller_pkh", "type" => "hash160"}, ...]}.
    # Types are advisory (rendering/validation hints), not consensus rules.
    field :args, :map, default: %{}
    field :source, :string

    timestamps()
  end

  @hash_re ~r/\A[0-9a-f]{64}\z/

  @doc false
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :template_hash, :body_asm, :args, :source])
    |> validate_required([:name, :template_hash])
    |> validate_format(:template_hash, @hash_re,
      message: "must be 64 lowercase hex chars (sha256)"
    )
    |> validate_length(:name, max: 200)
    |> validate_args_spec()
    |> unique_constraint(:template_hash)
    |> unique_constraint(:name)
  end

  # The args spec is advisory but must at least be shaped right: an "args"
  # list of %{"name" => ..., "type" => ...} maps (or absent/empty).
  defp validate_args_spec(changeset) do
    case get_field(changeset, :args) do
      nil ->
        changeset

      %{} = args when map_size(args) == 0 ->
        changeset

      %{"args" => list} when is_list(list) ->
        if Enum.all?(list, &valid_arg?/1) do
          changeset
        else
          add_error(changeset, :args, "each arg needs string \"name\" and \"type\" fields")
        end

      _ ->
        add_error(
          changeset,
          :args,
          "must be %{\"args\" => [%{\"name\" => ..., \"type\" => ...}]}"
        )
    end
  end

  defp valid_arg?(%{"name" => name, "type" => type}) when is_binary(name) and is_binary(type),
    do: true

  defp valid_arg?(_), do: false
end
