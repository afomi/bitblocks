defmodule Bitblocks.Protocol.Handlers.VCard do
  @moduledoc """
  vCard — contact cards inscribed as OP_RETURN text.
  Detected by the joined utf8 payload parsing as a vCard document.
  """

  use Bitblocks.Protocol.Handler,
    name: "vCard"

  alias Bitblocks.Protocol.Context

  @impl true
  def detect(%Context{utf8_chunks: utf8_chunks}) do
    utf8_chunks
    |> Enum.join("")
    |> Bitblocks.VcardParser.is_vcard?()
  end
end
