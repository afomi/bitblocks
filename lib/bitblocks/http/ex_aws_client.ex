defmodule Bitblocks.HTTP.ExAwsClient do
  @moduledoc """
  ExAws's HTTP client on Finch (`Bitblocks.HTTP`), set in `config/config.exs`
  as `config :ex_aws, http_client: ...`. ExAws's default is hackney, which we
  no longer ship (#65). Covers S3 (`Bitblocks.TxStore.S3`), EC2 tags
  (`Bitblocks.Cluster.Ec2Tags`) and the instance-metadata credentials.
  """

  @behaviour ExAws.Request.HttpClient

  @default_receive_timeout 30_000

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    opts = [
      receive_timeout:
        http_opts[:recv_timeout] || http_opts[:receive_timeout] || @default_receive_timeout
    ]

    case Bitblocks.HTTP.request(method, url, headers, body, opts) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status_code: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
end
