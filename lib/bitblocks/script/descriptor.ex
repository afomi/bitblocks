defmodule Bitblocks.Script.Descriptor do
  @moduledoc """
  Everything the rest of the system needs to know about one output's script,
  computed once: type, semantic fields, ASM, both content hashes, and the
  output's satoshis/vout.

  Built per output at analyze/render time so classification, hashing, and
  field extraction never have to be re-derived downstream (the transaction
  show page previously re-decoded `raw` several times per render).
  """

  alias Bitblocks.Script

  @type t :: %__MODULE__{
          vout: non_neg_integer(),
          satoshis: non_neg_integer(),
          type: Script.script_type(),
          fields: map(),
          asm: String.t(),
          script_hash: String.t(),
          template_hash: String.t()
        }

  defstruct [:vout, :satoshis, :type, :fields, :asm, :script_hash, :template_hash]

  @doc """
  Builds a descriptor for one `%BSV.TxOut{}` at output index `vout`.
  """
  def from_output(%BSV.TxOut{} = output, vout) when is_integer(vout) do
    script = output.script

    %__MODULE__{
      vout: vout,
      satoshis: output.satoshis,
      type: Script.classify(script),
      fields: Script.extract_fields(script),
      asm: BSV.Script.to_asm(script),
      script_hash: Script.script_hash(script),
      template_hash: Script.template_hash(script)
    }
  end

  @doc """
  Builds descriptors for every output of a decoded transaction.
  """
  def from_tx(%BSV.Tx{outputs: outputs}) do
    outputs
    |> Enum.with_index()
    |> Enum.map(fn {output, vout} -> from_output(output, vout) end)
  end
end
