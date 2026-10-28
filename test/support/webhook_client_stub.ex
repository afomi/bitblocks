defmodule Bitblocks.WebhookClientStub do
  @moduledoc """
  Test HTTP client for projection webhooks (config/test.exs). Sends
  `{:posted, url, body, headers}` to the calling process, which is the test
  process under Oban's `:manual` testing (`perform_job/2` runs inline), so
  async tests don't see each other's posts. Set the reply with
  `Process.put(:webhook_response, {:ok, status} | {:error, reason})`.
  """

  def post(url, body, headers) do
    send(self(), {:posted, url, body, Map.new(headers)})
    Process.get(:webhook_response, {:ok, 204})
  end
end
