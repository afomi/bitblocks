defmodule Bitblocks.Projections.WebhookTargetTest do
  @moduledoc """
  #29 step 5: a webhook can only reach a public host, checked when the URL is
  set and again before every delivery, so it can't aim Bitblocks at its own
  network (SSRF).
  """
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  alias Bitblocks.Projections
  alias Bitblocks.Projections.WebhookTarget
  alias Bitblocks.Workers.ProjectionWebhookWorker

  @filter %{"output_addresses" => ["1Donation"]}

  describe "public?/1" do
    test "refuses every private and reserved IPv4 range" do
      for address <- [
            {0, 0, 0, 0},
            {10, 1, 2, 3},
            {100, 64, 0, 1},
            {100, 127, 255, 255},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 0, 0, 1},
            {192, 0, 2, 1},
            {192, 168, 0, 1},
            {198, 18, 0, 1},
            {198, 19, 255, 255},
            {198, 51, 100, 1},
            {203, 0, 113, 1},
            {224, 0, 0, 1},
            {240, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        refute WebhookTarget.public?(address), inspect(address)
      end
    end

    test "allows the addresses either side of them" do
      for address <- [
            {9, 255, 255, 255},
            {11, 0, 0, 1},
            {100, 63, 255, 255},
            {100, 128, 0, 1},
            {172, 15, 255, 255},
            {172, 32, 0, 1},
            {192, 167, 255, 255},
            {192, 169, 0, 1},
            {93, 184, 216, 34}
          ] do
        assert WebhookTarget.public?(address), inspect(address)
      end
    end

    test "refuses private IPv6, and private IPv4 wrapped in IPv6" do
      for text <- [
            "::",
            "::1",
            "fc00::1",
            "fd12:3456:789a::1",
            "fe80::1",
            "fec0::1",
            "ff02::1",
            "2001:db8::1",
            "::ffff:10.0.0.1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.169.254",
            "64:ff9b::10.0.0.1",
            "2002:a00:1::1"
          ] do
        {:ok, address} = :inet.parse_address(String.to_charlist(text))
        refute WebhookTarget.public?(address), text
      end
    end

    test "allows public IPv6, and public IPv4 wrapped in it" do
      for text <- ["2606:2800:220:1:248:1893:25c8:1946", "::ffff:93.184.216.34"] do
        {:ok, address} = :inet.parse_address(String.to_charlist(text))
        assert WebhookTarget.public?(address), text
      end
    end
  end

  describe "check/1 and create/1" do
    test "refuses private hosts, whatever way they are written" do
      for url <- [
            "http://localhost/hook",
            "http://LOCALHOST:4000/hook",
            "http://foo.localhost/hook",
            "http://printer.local/hook",
            "http://db.internal/hook",
            "http://intranet/hook",
            "http://127.0.0.1/hook",
            "http://127.1/hook",
            "http://2130706433/hook",
            "http://0x7f.0.0.1/hook",
            "http://0177.0.0.1/hook",
            "http://10.0.1.5:8332/",
            "http://[::1]/hook",
            "http://[::ffff:10.0.0.1]/hook",
            "http://169.254.169.254/latest/meta-data/",
            "https://192.168.1.1/hook"
          ] do
        assert {:error, "must be a public host"} = WebhookTarget.check(url), url
      end
    end

    test "refuses a public name that resolves to a private address" do
      Process.put(:webhook_dns, %{"rebind.example" => [{93, 184, 216, 34}, {10, 0, 0, 1}]})
      assert {:error, "must be a public host"} = WebhookTarget.check("https://rebind.example/")
    end

    test "refuses a URL carrying a user, and one that isn't http(s)" do
      assert {:error, _} = WebhookTarget.check("https://user:pw@example.com/hook")
      assert {:error, _} = WebhookTarget.check("https://example.com@127.0.0.1/hook")
      assert {:error, _} = WebhookTarget.check("ftp://example.com/hook")
      assert {:error, _} = WebhookTarget.check("file:///etc/passwd")
    end

    test "a name that doesn't resolve yet can still be set; delivery checks again" do
      Process.put(:webhook_dns, %{"new.example" => []})
      assert :ok = WebhookTarget.check("https://new.example/hook")
    end

    test "create/1 and set_webhook/2 refuse a private target, with a reason" do
      assert {:error, changeset} =
               Projections.create(%{
                 tenant: "t",
                 name: "n",
                 filter: @filter,
                 webhook_url: "http://169.254.169.254/latest/"
               })

      assert %{webhook_url: ["must be a public host"]} = errors_on(changeset)

      {:ok, p} = Projections.create(%{tenant: "t", name: "m", filter: @filter})
      assert {:error, changeset} = Projections.set_webhook(p, "http://10.0.0.1/")
      assert %{webhook_url: ["must be a public host"]} = errors_on(changeset)
    end
  end

  describe "resolve/1" do
    test "https connects by name, so the certificate has to match it" do
      assert {:ok, "https://example.com/hook?a=1", []} =
               WebhookTarget.resolve("https://example.com/hook?a=1")
    end

    test "http connects to the address it checked, and names the host in a header" do
      assert {:ok, "http://93.184.216.34/hook?a=1", [{"host", "example.com"}]} =
               WebhookTarget.resolve("http://example.com/hook?a=1")

      assert {:ok, "http://93.184.216.34:8080/", [{"host", "example.com:8080"}]} =
               WebhookTarget.resolve("http://example.com:8080/")
    end

    test "http to an IPv6 name keeps the address well-formed" do
      Process.put(:webhook_dns, %{"six.example" => [{0x2606, 0x2800, 0, 0, 0, 0, 0, 1}]})

      assert {:ok, "http://[2606:2800::1]/", [{"host", "six.example"}]} =
               WebhookTarget.resolve("http://six.example/")
    end

    test "a name with no addresses retries" do
      Process.put(:webhook_dns, %{"gone.example" => []})
      assert {:retry, :nxdomain} = WebhookTarget.resolve("https://gone.example/")
    end
  end

  describe "delivery" do
    setup do
      {:ok, p} =
        Projections.create(%{
          tenant: "visible-dao",
          name: "donations",
          filter: @filter,
          webhook_url: "https://hooks.example/bitblocks"
        })

      %{
        projection: p,
        args: %{"projection_id" => p.id, "event" => "reorg", "rewind_height" => 5}
      }
    end

    test "a name that has since turned private is refused and never posted, and recorded",
         %{projection: p, args: args} do
      Process.put(:webhook_dns, %{"hooks.example" => [{169, 254, 169, 254}]})

      assert {:cancel, {:refused, "must be a public host"}} =
               perform_job(ProjectionWebhookWorker, args)

      refute_received {:posted, _, _, _}

      assert %{
               webhook_failures: 1,
               webhook_failed_event: "reorg",
               webhook_failed_status: "refused: must be a public host"
             } = Projections.get!(p.id)
    end

    test "a name that doesn't resolve retries without posting", %{args: args} do
      Process.put(:webhook_dns, %{"hooks.example" => []})
      assert {:error, :nxdomain} = perform_job(ProjectionWebhookWorker, args)
      refute_received {:posted, _, _, _}
    end

    test "an http delivery posts to the checked address, signed for the same body", %{
      projection: p,
      args: args
    } do
      {:ok, p} = Projections.set_webhook(p, "http://hooks.example/bitblocks")

      assert :ok = perform_job(ProjectionWebhookWorker, args)

      assert_received {:posted, "http://93.184.216.34/bitblocks", body, headers}
      assert headers["host"] == "hooks.example"

      assert Bitblocks.Projections.Webhook.verify(
               body,
               headers["x-bitblocks-signature"],
               p.webhook_secret
             )
    end

    test "only the last attempt's failure is recorded", %{projection: p, args: args} do
      Process.put(:webhook_response, {:ok, 500})

      assert {:error, {:http_status, 500}} =
               perform_job(ProjectionWebhookWorker, args, attempt: 3)

      assert %{webhook_failures: 0} = Projections.get!(p.id)

      assert {:error, {:http_status, 500}} =
               perform_job(ProjectionWebhookWorker, args, attempt: 10)

      assert %{
               webhook_failures: 1,
               webhook_failed_event: "reorg",
               webhook_failed_status: "{:http_status, 500}",
               webhook_failed_at: %DateTime{}
             } = Projections.get!(p.id)

      assert [%{id: id}] = Projections.webhook_failures()
      assert id == p.id
    end

    test "a failure's text is scrubbed", %{projection: p, args: args} do
      Process.put(:webhook_response, {:error, "refused by 10.0.0.5:8332"})
      perform_job(ProjectionWebhookWorker, args, attempt: 10)
      assert Projections.get!(p.id).webhook_failed_status =~ "[ip]"
    end

    test "setting the webhook again clears the record", %{projection: p} do
      Projections.record_webhook_failure(p, "tx", "{:http_status, 500}")
      assert [_] = Projections.webhook_failures()

      {:ok, _} = Projections.set_webhook(Projections.get!(p.id), p.webhook_url)
      assert Projections.webhook_failures() == []
    end
  end
end
