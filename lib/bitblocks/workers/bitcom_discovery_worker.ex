defmodule Bitblocks.Workers.BitcomDiscoveryWorker do
  @moduledoc """
  Walks one address's WhatsOnChain history for Bitcom commands (#24), one page
  per job, each job queuing the next, so a run survives a deploy and spends no
  more than the `:collections` lane's WhatsOnChain pace. `pages_left` bounds a
  run: a busy prefix's history is open-ended. See `Bitblocks.Bitcom.Discovery`.
  """

  use Oban.Worker,
    queue: :collections,
    max_attempts: 5,
    unique: [period: 3600, fields: [:args], keys: [:address, :token]]

  require Logger

  alias Bitblocks.Bitcom.Discovery

  @doc "The job for `address`, from `token`, with `pages` pages to go."
  def job(address, token \\ nil, pages \\ 50) do
    new(%{"address" => address, "token" => token, "pages_left" => pages})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"address" => address, "pages_left" => pages} = args}) do
    with {:ok, page} <- Discovery.scan_page(address, args["token"], apply: true) do
      Logger.info(
        "BitcomDiscovery #{address}: #{page.history} in history, #{page.fetched} fetched, " <>
          "#{page.logged} commands logged, #{page.proofs} proofs, #{pages - 1} pages to go"
      )

      continue(address, page.next_token, pages - 1)
    end
  end

  defp continue(address, token, pages) when is_binary(token) and pages > 0 do
    with {:ok, _job} <- Oban.insert(job(address, token, pages)), do: :ok
  end

  defp continue(address, token, _pages) do
    Logger.info("BitcomDiscovery #{address}: stopped, next token #{inspect(token)}")
    :ok
  end
end
