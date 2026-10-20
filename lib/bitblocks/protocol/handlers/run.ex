defmodule Bitblocks.Protocol.Handlers.Run do
  @moduledoc """
  Run — token protocol whose OP_RETURN envelope starts with hex `72756e`
  ("run").
  """

  use Bitblocks.Protocol.Handler,
    name: "Run"

  alias Bitblocks.Protocol.Context

  @impl true
  def detect(%Context{hex_joined: hex_joined}) do
    String.starts_with?(hex_joined, "72756e")
  end
end
