defmodule Bitblocks.Shutdown do
  @moduledoc """
  Whether this node is stopping: set once, from `Bitblocks.Application.prep_stop/1`,
  and read by long jobs between their batches, so they can stop at a clean
  boundary and hand their work on (`Bitblocks.BackfillChains`,
  https://github.com/afomi/bitblocks/issues/115).

  Why `prep_stop/1` and `:persistent_term`:

    * `prep_stop/1` runs on SIGTERM (a deploy's `init:stop/0`) before the
      supervision tree starts to stop, so the flag is up for the whole of
      Oban's `shutdown_grace_period`, whatever order the children stop in.
      A process trapping exits in the tree would only learn of the stop when
      its own turn came, which ties the flag to where that child sits.
    * `:persistent_term` costs nothing to read, so a batch loop can check it
      as often as it likes, and it needs no owner process that might already
      be gone. Writing it makes the VM scan every process once; that happens
      once, at shutdown.
  """

  @key {__MODULE__, :stopping}

  @doc "Marks this node as stopping. Called from `Application.prep_stop/1`."
  @spec begin() :: :ok
  def begin, do: :persistent_term.put(@key, true)

  @doc "True once this node has started to stop."
  @spec stopping?() :: boolean()
  def stopping?, do: :persistent_term.get(@key, false)

  @doc false
  # Tests only: a node never comes back from stopping.
  def reset do
    :persistent_term.erase(@key)
    :ok
  end
end
