defmodule Bitblocks.Protocol.Handlers.Bitcom do
  @moduledoc """
  Bitcom commands — a piped segment that starts with `$`
  (`$ useradd <address>`, `$ echo …`, `$ route add …`).

  `$ useradd <address>` claims a protocol prefix. It proves ownership only when
  the tx was spent from `<address>`; `Bitblocks.Chain.index_bitcom/1` checks
  that against the first-input address and records the proof.
  """

  use Bitblocks.Protocol.Handler,
    name: "Bitcom",
    exact: "$"

  alias Bitblocks.Script.OpReturn

  @impl true
  def parse(data_chunks) when is_list(data_chunks) do
    data_chunks
    |> OpReturn.utf8_chunks()
    |> OpReturn.pipe_segments()
    |> Enum.find_value({:error, :no_bitcom_command}, fn
      ["$", command | args] -> {:ok, %{protocol: "Bitcom", command: command, args: args}}
      _ -> nil
    end)
  end

  @doc """
  The address a `$ useradd` segment claims, or nil.
  """
  def useradd_address(data_chunks) when is_list(data_chunks) do
    case parse(data_chunks) do
      {:ok, %{command: "useradd", args: [address | _]}} -> address
      _ -> nil
    end
  end
end
