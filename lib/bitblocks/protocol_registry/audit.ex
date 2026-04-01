defmodule Bitblocks.ProtocolRegistry.Audit do
  @moduledoc """
  Audit records for protocol verification.

  Tracks security audits, specification compliance checks,
  and interoperability testing results.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @audit_types ~w(security spec_compliance interop)
  @results ~w(pass fail warning)

  schema "protocol_audits" do
    belongs_to :protocol, Bitblocks.ProtocolRegistry.Protocol

    field :auditor, :string
    field :audit_type, :string
    field :result, :string
    field :notes, :string
    field :report_url, :string
    field :audit_date, :date

    timestamps()
  end

  @doc false
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [
      :protocol_id,
      :auditor,
      :audit_type,
      :result,
      :notes,
      :report_url,
      :audit_date
    ])
    |> validate_required([:protocol_id, :auditor, :audit_type, :result, :audit_date])
    |> validate_inclusion(:audit_type, @audit_types)
    |> validate_inclusion(:result, @results)
  end

  @doc """
  Returns all valid audit types.
  """
  def audit_types, do: @audit_types

  @doc """
  Returns all valid result types.
  """
  def results, do: @results
end
