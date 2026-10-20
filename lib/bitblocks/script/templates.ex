defmodule Bitblocks.Script.Templates do
  @moduledoc """
  Context for the script template registry.

  Register a template (name + template_hash + arg spec), then every on-chain
  instance — past and future — is one GIN lookup away
  (`Bitblocks.Chain.history_for_template_hash/1`).
  """

  import Ecto.Query

  alias Bitblocks.Repo
  alias Bitblocks.Script.Template

  @doc "All registered templates, newest first."
  def list do
    Repo.all(from t in Template, order_by: [desc: t.inserted_at])
  end

  @doc "Registers a template. `{:ok, template}` or `{:error, changeset}`."
  def register(attrs) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
  end

  @doc "The template registered under `template_hash`, or nil."
  def get_by_hash(template_hash) when is_binary(template_hash) do
    Repo.get_by(Template, template_hash: template_hash)
  end

  @doc """
  Matches a `%BSV.Script{}` against the registry: computes its template hash
  and returns the registered template, or nil.
  """
  def match(%BSV.Script{} = script) do
    script
    |> Bitblocks.Script.template_hash()
    |> get_by_hash()
  end
end
