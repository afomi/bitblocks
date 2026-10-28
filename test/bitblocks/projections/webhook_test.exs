defmodule Bitblocks.Projections.WebhookTest do
  @moduledoc """
  #29 step 4: follow by webhook. A block completing at the tip enqueues one
  signed delivery per matching tx; a reorg enqueues a rewind.
  """
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures

  alias Bitblocks.Projections
  alias Bitblocks.Projections.Webhook
  alias Bitblocks.Workers.ProjectionWebhookWorker

  @donation "1DonationAddressXXXXXXXXXXXXXXXXX"

  setup do
    {:ok, p} =
      Projections.create(%{
        tenant: "visible-dao",
        name: "donations",
        filter: %{"output_addresses" => [@donation]},
        from_height: 100,
        webhook_url: "https://visibledao.example/hooks/bitblocks"
      })

    %{projection: p}
  end

  defp donation(height, hash, n) do
    transaction_fixture(%{
      block_height: height,
      block_hash: hash,
      txid: String.duplicate("#{n}", 64),
      output_addresses: [@donation]
    })
  end

  describe "create/1 with a webhook" do
    test "generates a signing secret", %{projection: p} do
      assert p.webhook_secret =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "rejects a webhook URL that isn't http(s)" do
      assert {:error, changeset} =
               Projections.create(%{
                 tenant: "t",
                 name: "n",
                 filter: %{"output_addresses" => [@donation]},
                 webhook_url: "ftp://x"
               })

      assert %{webhook_url: [_]} = errors_on(changeset)
    end
  end

  describe "set_webhook/2" do
    test "rotates the secret on every set, and clears both on nil", %{projection: p} do
      {:ok, rotated} = Projections.set_webhook(p, p.webhook_url)
      assert rotated.webhook_secret =~ ~r/\A[0-9a-f]{64}\z/
      refute rotated.webhook_secret == p.webhook_secret

      assert Projections.get!(p.id).webhook_secret == rotated.webhook_secret

      {:ok, _} = Projections.set_webhook(rotated, nil)
      cleared = Projections.get!(p.id)
      assert is_nil(cleared.webhook_url) and is_nil(cleared.webhook_secret)
    end
  end

  describe "notify_block/1" do
    test "enqueues exactly one delivery per matching tx in the block", %{projection: p} do
      block = block_fixture(%{height: 120, sync_state: "completed"})
      tx = donation(120, block.hash, 1)
      _other_block = donation(121, "another", 2)
      _unrelated = transaction_fixture(%{block_height: 120, block_hash: block.hash})

      assert Projections.notify_block(block) == 1
      assert Projections.notify_block(block) == 0

      assert [job] = all_enqueued(worker: ProjectionWebhookWorker)

      assert job.args == %{
               "projection_id" => p.id,
               "event" => "tx",
               "txid" => tx.txid,
               "block_height" => 120,
               "block_hash" => block.hash
             }
    end

    test "skips paused projections, hydrate-only ones, and blocks below from_height", %{
      projection: p
    } do
      {:ok, _} =
        Projections.create(%{
          tenant: "t",
          name: "hydrate-only",
          filter: %{"output_addresses" => [@donation]}
        })

      low = block_fixture(%{height: 99})
      donation(99, low.hash, 1)
      assert Projections.notify_block(low) == 0

      p |> Ecto.Changeset.change(status: "paused") |> Repo.update!()
      block = block_fixture(%{height: 120})
      donation(120, block.hash, 2)
      assert Projections.notify_block(block) == 0

      refute_enqueued(worker: ProjectionWebhookWorker)
    end
  end

  describe "notify_reorg/1" do
    test "enqueues a rewind to the fork point for each webhook projection", %{projection: p} do
      assert Projections.notify_reorg(150) == 1

      assert_enqueued(
        worker: ProjectionWebhookWorker,
        args: %{"projection_id" => p.id, "event" => "reorg", "rewind_height" => 150}
      )
    end
  end

  describe "delivery" do
    # config/test.exs points the client at Bitblocks.WebhookClientStub.
    test "POSTs a signed tx event the tenant can verify", %{projection: p} do
      args = %{
        "projection_id" => p.id,
        "event" => "tx",
        "txid" => String.duplicate("1", 64),
        "block_height" => 120,
        "block_hash" => "h"
      }

      assert :ok = perform_job(ProjectionWebhookWorker, args)
      assert_received {:posted, url, body, headers}

      assert url == p.webhook_url
      assert headers["x-bitblocks-event"] == "tx"
      assert Webhook.verify(body, headers["x-bitblocks-signature"], p.webhook_secret)
      refute Webhook.verify(body <> " ", headers["x-bitblocks-signature"], p.webhook_secret)

      assert %{
               "event" => "tx",
               "projection_id" => id,
               "definition_hash" => hash,
               "txid" => _,
               "block_height" => 120,
               "proof_url" => "/api/v1/txs/" <> _
             } = Jason.decode!(body)

      assert id == p.id and hash == p.definition_hash
    end

    test "a non-2xx response or a transport error is retried", %{projection: p} do
      args = %{"projection_id" => p.id, "event" => "reorg", "rewind_height" => 150}

      Process.put(:webhook_response, {:ok, 500})
      assert {:error, {:http_status, 500}} = perform_job(ProjectionWebhookWorker, args)

      Process.put(:webhook_response, {:error, :timeout})
      assert {:error, :timeout} = perform_job(ProjectionWebhookWorker, args)
    end

    test "a paused or deleted projection cancels instead of posting", %{projection: p} do
      args = %{"projection_id" => p.id, "event" => "reorg", "rewind_height" => 150}

      p |> Ecto.Changeset.change(status: "paused") |> Repo.update!()
      assert {:cancel, :paused} = perform_job(ProjectionWebhookWorker, args)

      Repo.delete!(p)
      assert {:cancel, :projection_not_found} = perform_job(ProjectionWebhookWorker, args)
      refute_received {:posted, _, _, _}
    end
  end
end
