defmodule Bitblocks.WebhookResolverStub do
  @moduledoc """
  Test DNS for projection webhooks (config/test.exs). Answers from the calling
  process's `:webhook_dns` map, host => addresses, and otherwise with one
  public address, so tests need no network.
  """

  def addresses(host), do: Map.get(Process.get(:webhook_dns, %{}), host, [{93, 184, 216, 34}])
end
