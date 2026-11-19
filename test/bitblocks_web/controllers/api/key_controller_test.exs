defmodule BitblocksWeb.Api.KeyControllerTest do
  @moduledoc "#121: an API key by signing a challenge, no account."
  use BitblocksWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:bitblocks, :signed_keys_per_ip_per_minute)
    Application.put_env(:bitblocks, :signed_keys_per_ip_per_minute, 1_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :signed_keys_per_ip_per_minute, previous),
        else: Application.delete_env(:bitblocks, :signed_keys_per_ip_per_minute)
    end)

    privkey = BSV.PrivKey.new()

    address =
      privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

    %{privkey: privkey, address: address}
  end

  defp challenge(conn) do
    conn |> get(~p"/api/v1/keys/challenge") |> json_response(200) |> Map.fetch!("data")
  end

  defp redeem(conn, body), do: post(conn, ~p"/api/v1/keys", body)

  test "challenge, sign, redeem, then call the API with the key", ctx do
    data = challenge(build_conn())
    assert data["message"] =~ "Nonce: "
    assert data["message"] =~ "Site: https://"
    assert data["expires_at"]

    signature = BSV.Message.sign(data["message"], ctx.privkey)

    body =
      build_conn()
      |> redeem(%{"challenge" => data["challenge"], "signature" => signature})
      |> json_response(201)
      |> Map.fetch!("data")

    assert body["address"] == ctx.address
    assert "bbk_" <> _ = body["key"]
    assert Bitblocks.ApiKeys.verify(body["key"]).address == ctx.address
  end

  test "a challenge redeemed twice is a 409", ctx do
    data = challenge(build_conn())

    params = %{
      "challenge" => data["challenge"],
      "signature" => BSV.Message.sign(data["message"], ctx.privkey)
    }

    assert build_conn() |> redeem(params) |> json_response(201)

    assert %{"error" => "challenge already used" <> _} =
             build_conn() |> redeem(params) |> json_response(409)
  end

  test "a challenge this site didn't make is a 401", ctx do
    signature = BSV.Message.sign("anything", ctx.privkey)

    assert %{"error" => "not a challenge from this site"} =
             build_conn()
             |> redeem(%{"challenge" => "forged", "signature" => signature})
             |> json_response(401)
  end

  test "an expired challenge is a 401", ctx do
    nonce = "00112233445566778899aabbccddeeff"
    old = System.system_time(:second) - 600

    token =
      Phoenix.Token.sign(
        BitblocksWeb.Endpoint,
        "api key challenge v1",
        %{"n" => nonce, "t" => old},
        signed_at: old
      )

    signature = BSV.Message.sign("whatever", ctx.privkey)

    assert %{"error" => "challenge expired" <> _} =
             build_conn()
             |> redeem(%{"challenge" => token, "signature" => signature})
             |> json_response(401)
  end

  test "a signature that doesn't parse is a 401" do
    data = challenge(build_conn())

    assert %{"error" => "the signature doesn't verify" <> _} =
             build_conn()
             |> redeem(%{"challenge" => data["challenge"], "signature" => "nope"})
             |> json_response(401)
  end

  test "signing other text, with the address sent, is a 401", ctx do
    data = challenge(build_conn())
    signature = BSV.Message.sign(data["message"] <> " ", ctx.privkey)

    assert %{"error" => "the signature is from " <> _} =
             build_conn()
             |> redeem(%{
               "challenge" => data["challenge"],
               "signature" => signature,
               "address" => ctx.address
             })
             |> json_response(401)
  end

  test "an address given that didn't sign is a 401 naming the signer", ctx do
    data = challenge(build_conn())

    other =
      BSV.PrivKey.new()
      |> BSV.PubKey.from_privkey()
      |> BSV.Address.from_pubkey()
      |> BSV.Address.to_string()

    assert %{"error" => error} =
             build_conn()
             |> redeem(%{
               "challenge" => data["challenge"],
               "signature" => BSV.Message.sign(data["message"], ctx.privkey),
               "address" => other
             })
             |> json_response(401)

    assert error =~ ctx.address
  end

  test "missing fields are a 400" do
    assert %{"error" => "send challenge and signature" <> _} =
             build_conn() |> redeem(%{}) |> json_response(400)
  end

  test "past the per-IP limit it's a 429 with Retry-After", ctx do
    Application.put_env(:bitblocks, :signed_keys_per_ip_per_minute, 1)
    ip = "203.0.113.#{:rand.uniform(250)}"

    attempt = fn ->
      data = challenge(build_conn())

      build_conn()
      |> put_req_header("x-forwarded-for", ip)
      |> redeem(%{
        "challenge" => data["challenge"],
        "signature" => BSV.Message.sign(data["message"], ctx.privkey)
      })
    end

    assert attempt.().status == 201
    limited = attempt.()
    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") == ["60"]
  end
end
