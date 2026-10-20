defmodule Bitblocks.Protocol.Handlers.Ordinals do
  @moduledoc """
  1SAT Ordinals — inscription envelopes.
  Detected by an `ord`-prefixed segment or the `ord` marker (hex `6f7264`)
  anywhere in the OP_RETURN data.
  """

  use Bitblocks.Protocol.Handler,
    name: "1SAT Ordinals",
    prefix: "ord"

  alias Bitblocks.Protocol.Context

  @impl true
  def detect(%Context{hex_joined: hex_joined}) do
    String.contains?(hex_joined, "6f7264")
  end
end
