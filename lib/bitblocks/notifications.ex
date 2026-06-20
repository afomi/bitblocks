defmodule Bitblocks.Notifications do
  @moduledoc """
  Sends operational alert emails via Bitblocks.Mailer (AWS SES in prod).

  The From address is read from MAILER_FROM at runtime and must be @bitblocks.app
  (IAM condition enforces this).
  """
  import Swoosh.Email

  alias Bitblocks.Mailer

  @to "wold@afomi.com"

  @doc """
  Sends a reorg alert email to the operator.

    - fork_height: the block height at which the chain diverged
    - fork_point: the last common ancestor height (nil if too deep to resolve)
    - orphan_count: number of orphaned blocks deleted (nil if unresolved)
  """
  def reorg_alert(fork_height, fork_point, orphan_count) do
    from_address = System.get_env("MAILER_FROM", "alerts@bitblocks.app")

    subject =
      if fork_point do
        "Bitblocks: reorg at #{fork_height} (#{orphan_count} orphan(s) resolved)"
      else
        "Bitblocks: reorg at #{fork_height} — manual intervention required"
      end

    body =
      if fork_point do
        """
        A chain reorganization was detected and resolved.

        Fork height:  #{fork_height}
        Fork point:   #{fork_point}
        Orphans deleted: #{orphan_count}

        Re-sync from #{fork_point + 1} has been queued.
        """
      else
        """
        A chain reorganization was detected but could not be resolved automatically.
        The fork exceeds the maximum safe reorg depth.

        Fork height: #{fork_height}

        Manual intervention is required. Check the node and the DB state.
        """
      end

    email =
      new()
      |> to(@to)
      |> from({"Bitblocks", from_address})
      |> subject(subject)
      |> text_body(body)

    Mailer.deliver(email)
  end
end
