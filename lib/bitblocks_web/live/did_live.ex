defmodule BitblocksWeb.DIDLive do
  use BitblocksWeb, :live_view
  alias JOSE.{JWK, JWS}
  alias Bitblocks.VanityDID
  import Bitwise

  @impl true
  def mount(_params, _session, socket) do
    :inets.start()
    :ssl.start()

    {:ok,
     socket
     |> assign(:tab, :did)
     |> assign(:host, "ryanwold.net")
     |> assign(:path, "")
     # "ES256" | "EdDSA"
     |> assign(:alg, "ES256")
     |> assign(:did, nil)
     |> assign(:did_url, nil)
     |> assign(:pub_jwk_json, "")
     |> assign(:priv_jwk_json, "")
     |> assign(:did_doc_json, "")
     |> assign(:issuer_did, "")
     |> assign(:issuer_kid, "")
     |> assign(:holder_did, "did:web:ryanwold.net")
     |> assign(:issue_alg, "ES256")
     |> assign(:valid_days, "365")
     |> assign(:issuer_priv_jwk, "")
     |> assign(:name, "Ryan Wold")
     |> assign(:license, "D-123-456-CA")
     |> assign(:status_url, "")
     |> assign(:status_idx, "")
     |> assign(:vc_jwt, "")
     |> assign(:verify_jwt, "")
     |> assign(:verify_aud, "")
     |> assign(:verify_nonce, "")
     |> assign(:verify_result, "")
     |> assign(:verify_log, "")
     |> assign(:verified_payload_json, "")
     # Vanity DID assigns
     |> assign(:vanity_prefix, "")
     |> assign(:vanity_host, "ryanwold.net")
     |> assign(:vanity_path, "")
     |> assign(:vanity_case_sensitive, false)
     |> assign(:vanity_suffix, false)
     |> assign(:vanity_searching, false)
     |> assign(:vanity_attempts, 0)
     |> assign(:vanity_result, nil)
     |> assign(:vanity_error, nil)}
  end

  # ---------- Events ----------

  @impl true
  def handle_event("switch", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("gen_did", params, socket) do
    host = String.trim(params["host"] || "")
    path = String.trim(params["path"] || "")
    alg = params["alg"] || "ES256"

    if host == "" do
      {:noreply, put_flash(socket, :error, "Host is required")}
    else
      did = did_from_host_path(host, path)

      {pub_jwk, priv_jwk} =
        case alg do
          "ES256" ->
            {pub_jwk, priv_jwk} = gen_p256_jwks()

          "EdDSA" ->
            {pub_jwk, priv_jwk} = gen_ed25519_jwks()
        end

      kid = did <> "#key-1"

      did_doc = %{
        "id" => did,
        "verificationMethod" => [
          %{
            "id" => kid,
            "type" => "JsonWebKey2020",
            "controller" => did,
            "publicKeyJwk" => pub_jwk
          }
        ],
        "assertionMethod" => [kid],
        "authentication" => [kid],
        "service" => [
          %{
            "id" => did <> "#status",
            "type" => "StatusList2021Service",
            "serviceEndpoint" => "https://#{host}/credentials/status/2021"
          }
        ]
      }

      {:noreply,
       socket
       |> assign(:did, did)
       |> assign(:did_url, did_web_url(did))
       |> assign(:pub_jwk_json, json(pub_jwk))
       |> assign(:priv_jwk_json, json(priv_jwk))
       |> assign(:did_doc_json, json(did_doc))}
    end
  end

  @impl true
  def handle_event("sign_vc", params, socket) do
    issuer_did = String.trim(params["issuer_did"] || "")
    holder_did = String.trim(params["holder_did"] || "")
    kid = String.trim(params["issuer_kid"] || issuer_did <> "#key-1")
    alg = params["issue_alg"] || "ES256"
    valid_days = to_int(params["valid_days"], 365)
    name = String.trim(params["name"] || "Example Holder")
    license = String.trim(params["license"] || "D-123-456-CA")
    status_url = String.trim(params["status_url"] || "")
    status_idx = String.trim(params["status_idx"] || "")
    priv_jwk_text = params["issuer_priv_jwk"] || ""

    with :ok <- nonempty(issuer_did, "Issuer DID"),
         :ok <- nonempty(holder_did, "Holder DID"),
         {:ok, jwk_map} <- Jason.decode(priv_jwk_text),
         jwk <- JWK.from_map(jwk_map) do
      now = System.os_time(:second)
      exp = now + valid_days * 24 * 60 * 60

      credential_status =
        if status_url != "" and status_idx != "" do
          %{
            "id" => status_url <> "#" <> status_idx,
            "type" => "StatusList2021Entry",
            "statusPurpose" => "revocation",
            "statusListIndex" => status_idx,
            "statusListCredential" => status_url
          }
        else
          nil
        end

      vc_claims = %{
        "iss" => issuer_did,
        "sub" => holder_did,
        "nbf" => now,
        "iat" => now,
        "exp" => exp,
        "jti" => "urn:uuid:" <> Ecto.UUID.generate(),
        "vc" => %{
          "@context" => ["https://www.w3.org/2018/credentials/v1"],
          "type" => ["VerifiableCredential", "DriverLicenseCredential"],
          "credentialSubject" => %{
            "id" => holder_did,
            "name" => name,
            "licenseNumber" => license
          }
        }
      }

      vc_claims =
        if credential_status,
          do: put_in(vc_claims, ["vc", "credentialStatus"], credential_status),
          else: vc_claims

      headers = %{"alg" => alg, "kid" => kid, "typ" => "JWT"}
      payload = Jason.encode!(vc_claims)

      jws = JWS.sign(jwk, payload, headers)
      {_obj, compact} = JWS.compact(jws)

      {:noreply, assign(socket, :vc_jwt, compact)}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, "Issuer Private JWK is not valid JSON")}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("verify", params, socket) do
    jwt = String.trim(params["verify_jwt"] || "")
    aud = String.trim(params["verify_aud"] || "")
    nonce = String.trim(params["verify_nonce"] || "")

    case verify_token(jwt, aud: present(aud), nonce: present(nonce)) do
      {:ok, %{type: type, payload: payload}} ->
        {:noreply,
         socket
         |> assign(:verify_result, "VALID (#{type}) ✅")
         |> assign(:verify_log, "")
         |> assign(:verified_payload_json, json(payload))}

      {:error, reason, payload} when is_map(payload) ->
        {:noreply,
         socket
         |> assign(:verify_result, "INVALID ❌")
         |> assign(:verify_log, reason)
         |> assign(:verified_payload_json, json(payload))}

      {:error, reason, _} ->
        {:noreply,
         socket
         |> assign(:verify_result, "INVALID ❌")
         |> assign(:verify_log, reason)
         |> assign(:verified_payload_json, "")}
    end
  end

  @impl true
  def handle_event("search_vanity", params, socket) do
    prefix = String.trim(params["vanity_prefix"] || "")
    host = String.trim(params["vanity_host"] || "")
    path = String.trim(params["vanity_path"] || "")
    case_sensitive = params["vanity_case_sensitive"] == "true"
    suffix = params["vanity_suffix"] == "true"

    cond do
      prefix == "" ->
        {:noreply, put_flash(socket, :error, "Prefix is required")}

      host == "" ->
        {:noreply, put_flash(socket, :error, "Host is required")}

      true ->
        case VanityDID.validate_prefix(prefix) do
          {:error, invalid_chars} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Invalid Base58 characters: #{Enum.join(invalid_chars, ", ")}"
             )}

          :ok ->
            # Start the search in a separate process
            lv_pid = self()

            Task.start(fn ->
              result =
                VanityDID.search(prefix,
                  case_sensitive: case_sensitive,
                  suffix: suffix,
                  max_attempts: 5_000_000,
                  progress_callback: fn attempts ->
                    send(lv_pid, {:vanity_progress, attempts})
                  end
                )

              send(lv_pid, {:vanity_result, result, host, path})
            end)

            difficulty = VanityDID.estimate_difficulty(String.length(prefix), case_sensitive)

            {:noreply,
             socket
             |> assign(:vanity_searching, true)
             |> assign(:vanity_attempts, 0)
             |> assign(:vanity_result, nil)
             |> assign(:vanity_error, nil)
             |> assign(:vanity_difficulty, difficulty)}
        end
    end
  end

  @impl true
  def handle_info({:vanity_progress, attempts}, socket) do
    {:noreply, assign(socket, :vanity_attempts, attempts)}
  end

  @impl true
  def handle_info({:vanity_result, result, host, path}, socket) do
    case result do
      {:ok, vanity_result} ->
        # Build the DID and DID document
        did = did_from_host_path(host, path)
        kid = did <> "#key-1"

        pub_jwk = VanityDID.pubkey_to_jwk(vanity_result.pub_key)
        priv_jwk = VanityDID.privkey_to_jwk(vanity_result.priv_key, vanity_result.pub_key)

        did_doc = %{
          "id" => did,
          "verificationMethod" => [
            %{
              "id" => kid,
              "type" => "JsonWebKey2020",
              "controller" => did,
              "publicKeyJwk" => pub_jwk
            }
          ],
          "assertionMethod" => [kid],
          "authentication" => [kid],
          "service" => [
            %{
              "id" => did <> "#status",
              "type" => "StatusList2021Service",
              "serviceEndpoint" => "https://#{host}/credentials/status/2021"
            }
          ]
        }

        {:noreply,
         socket
         |> assign(:vanity_searching, false)
         |> assign(:vanity_attempts, vanity_result.attempts)
         |> assign(
           :vanity_result,
           Map.merge(vanity_result, %{
             did: did,
             did_url: did_web_url(did),
             pub_jwk: pub_jwk,
             priv_jwk: priv_jwk,
             did_doc: did_doc
           })
         )}

      {:error, :timeout, attempts} ->
        {:noreply,
         socket
         |> assign(:vanity_searching, false)
         |> assign(:vanity_attempts, attempts)
         |> assign(
           :vanity_error,
           "Search timed out after #{VanityDID.format_number(attempts)} attempts"
         )}
    end
  end

  defp gen_p256_jwks() do
    # OID for P-256 is 1.2.840.10045.3.1.7
    ec_priv = :public_key.generate_key({:namedCurve, {1, 2, 840, 10045, 3, 1, 7}})

    # OTP 26/27 tuple form includes :asn1_NOVALUE at the end
    {:ECPrivateKey, :ecPrivkeyVer1, d, {:namedCurve, _oid}, pub_oct, _attrs} = ec_priv

    # Uncompressed point: 0x04 || X(32) || Y(32)
    <<4, x::binary-32, y::binary-32>> = pub_oct

    pub = %{
      "kty" => "EC",
      "crv" => "P-256",
      "x" => b64url(x),
      "y" => b64url(y)
    }

    priv = Map.put(pub, "d", b64url(d))
    {pub, priv}
  end

  defp gen_ed25519_jwks() do
    # OKP path still works fine with JOSE
    jwk = JOSE.JWK.generate_key({:okp, :Ed25519})
    {m, _} = JOSE.JWK.to_map(jwk)
    pub = Map.drop(m, ["d"])
    {pub, m}
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  # ---------- Rendering ----------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto px-4 py-8">
      <h1 class="text-2xl font-semibold">DID Playground (Single Account)</h1>

      <div class="mt-6 flex gap-2 flex-wrap">
        <button
          phx-click="switch"
          phx-value-tab="did"
          class={"px-3 py-2 rounded-xl border #{if @tab==:did, do: "bg-indigo-600 text-white", else: "bg-white"}"}
        >
          Create DID
        </button>
        <button
          phx-click="switch"
          phx-value-tab="vanity"
          class={"px-3 py-2 rounded-xl border #{if @tab==:vanity, do: "bg-indigo-600 text-white", else: "bg-white"}"}
        >
          Vanity DID
        </button>
        <button
          phx-click="switch"
          phx-value-tab="issue"
          class={"px-3 py-2 rounded-xl border #{if @tab==:issue, do: "bg-indigo-600 text-white", else: "bg-white"}"}
        >
          Issuance
        </button>
        <button
          phx-click="switch"
          phx-value-tab="verify"
          class={"px-3 py-2 rounded-xl border #{if @tab==:verify, do: "bg-indigo-600 text-white", else: "bg-white"}"}
        >
          Verification
        </button>
      </div>

      <!-- DID CREATION -->
      <%= if @tab == :did do %>
        <div class="mt-6 rounded-2xl border p-4 bg-white">
          <h2 class="font-semibold text-lg">Create DID (did:web)</h2>
          <.simple_form for={:did} phx-submit="gen_did" class="grid md:grid-cols-3 gap-4 mt-4">
            <.input name="host" value={@host} label="Host" placeholder="ryanwold.net" />
            <.input name="path" value={@path} label="Path (optional)" placeholder="dept/dmv" />
            <.input type="select" name="alg" value={@alg} label="Algorithm" options={["ES256", "EdDSA"]} />
            <:actions>
              <.button class="mt-2">Generate</.button>
            </:actions>
          </.simple_form>

          <%= if @did do %>
            <div class="mt-6 grid md:grid-cols-2 gap-4">
              <div class="rounded-xl border p-3">
                <p class="text-sm text-slate-600">DID</p>
                <p class="font-mono text-sm break-all"><%= @did %></p>
                <p class="text-sm text-slate-600 mt-3">Publish at</p>
                <a class="font-mono text-xs text-indigo-700 underline break-all" href={@did_url} target="_blank"><%= @did_url %></a>
              </div>
              <div class="rounded-xl border p-3">
                <p class="font-semibold">Public JWK</p>
                <textarea class="w-full h-48 font-mono text-xs border rounded-lg p-2"><%= @pub_jwk_json %></textarea>
              </div>
            </div>

            <div class="mt-4 grid md:grid-cols-2 gap-4">
              <div class="rounded-xl border p-3">
                <p class="font-semibold">Private JWK (keep secret)</p>
                <textarea class="w-full h-48 font-mono text-xs border rounded-lg p-2"><%= @priv_jwk_json %></textarea>
              </div>
              <div class="rounded-xl border p-3">
                <p class="font-semibold">did.json</p>
                <textarea class="w-full h-48 font-mono text-xs border rounded-lg p-2"><%= @did_doc_json %></textarea>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- VANITY DID -->
      <%= if @tab == :vanity do %>
        <div class="mt-6 rounded-2xl border p-4 bg-white">
          <h2 class="font-semibold text-lg">Vanity DID (secp256k1)</h2>
          <p class="text-sm text-slate-600 mt-1">
            Generate a DID with a Bitcoin address matching your prefix.
            Uses the same key for both DID signing and Bitcoin transactions.
          </p>

          <.simple_form
            for={:vanity}
            phx-submit="search_vanity"
            class="grid md:grid-cols-3 gap-4 mt-4"
          >
            <.input
              name="vanity_prefix"
              value={@vanity_prefix}
              label="Prefix (after '1')"
              placeholder="Ryan"
            />
            <.input
              name="vanity_host"
              value={@vanity_host}
              label="Host"
              placeholder="ryanwold.net"
            />
            <.input
              name="vanity_path"
              value={@vanity_path}
              label="Path (optional)"
              placeholder="dept/id"
            />
            <div class="flex items-center gap-4 md:col-span-3">
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="vanity_case_sensitive"
                  value="true"
                  checked={@vanity_case_sensitive}
                  class="rounded"
                />
                <span class="text-sm">Case sensitive</span>
              </label>
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="vanity_suffix"
                  value="true"
                  checked={@vanity_suffix}
                  class="rounded"
                />
                <span class="text-sm">Match suffix</span>
              </label>
            </div>
            <:actions>
              <.button
                class="mt-2"
                disabled={@vanity_searching}
              >
                <%= if @vanity_searching, do: "Searching...", else: "Search" %>
              </.button>
            </:actions>
          </.simple_form>

          <%= if @vanity_searching do %>
            <div class="mt-4 p-4 rounded-xl border bg-slate-50">
              <div class="flex items-center gap-3">
                <div class="animate-spin h-5 w-5 border-2 border-indigo-600 border-t-transparent rounded-full"></div>
                <span>Searching... <%= VanityDID.format_number(@vanity_attempts) %> attempts</span>
              </div>
              <%= if assigns[:vanity_difficulty] do %>
                <p class="text-xs text-slate-500 mt-2">
                  Estimated attempts needed: ~<%= VanityDID.format_number(@vanity_difficulty) %>
                </p>
              <% end %>
            </div>
          <% end %>

          <%= if @vanity_error do %>
            <div class="mt-4 p-4 rounded-xl border bg-red-50 text-red-700">
              <%= @vanity_error %>
            </div>
          <% end %>

          <%= if @vanity_result do %>
            <div class="mt-6 grid md:grid-cols-2 gap-4">
              <div class="rounded-xl border p-3 bg-green-50">
                <p class="font-semibold text-green-700">Found in <%= VanityDID.format_number(@vanity_result.attempts) %> attempts!</p>
                <p class="text-sm text-slate-600 mt-2">Bitcoin Address</p>
                <p class="font-mono text-sm break-all"><%= @vanity_result.address %></p>
                <p class="text-sm text-slate-600 mt-3">DID</p>
                <p class="font-mono text-sm break-all"><%= @vanity_result.did %></p>
                <p class="text-sm text-slate-600 mt-3">Publish at</p>
                <a
                  class="font-mono text-xs text-indigo-700 underline break-all"
                  href={@vanity_result.did_url}
                  target="_blank"
                >
                  <%= @vanity_result.did_url %>
                </a>
              </div>
              <div class="rounded-xl border p-3">
                <p class="font-semibold">WIF (Bitcoin private key)</p>
                <textarea
                  class="w-full h-20 font-mono text-xs border rounded-lg p-2"
                  readonly
                ><%= @vanity_result.wif %></textarea>
              </div>
            </div>

            <div class="mt-4 grid md:grid-cols-2 gap-4">
              <div class="rounded-xl border p-3">
                <p class="font-semibold">Public JWK (secp256k1)</p>
                <textarea
                  class="w-full h-48 font-mono text-xs border rounded-lg p-2"
                  readonly
                ><%= json(@vanity_result.pub_jwk) %></textarea>
              </div>
              <div class="rounded-xl border p-3">
                <p class="font-semibold">Private JWK (keep secret)</p>
                <textarea
                  class="w-full h-48 font-mono text-xs border rounded-lg p-2"
                  readonly
                ><%= json(@vanity_result.priv_jwk) %></textarea>
              </div>
            </div>

            <div class="mt-4">
              <div class="rounded-xl border p-3">
                <p class="font-semibold">did.json</p>
                <textarea
                  class="w-full h-64 font-mono text-xs border rounded-lg p-2"
                  readonly
                ><%= json(@vanity_result.did_doc) %></textarea>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- ISSUANCE -->
      <%= if @tab == :issue do %>
        <div class="mt-6 rounded-2xl border p-4 bg-white">
          <h2 class="font-semibold text-lg">Issue Verifiable Credential (JWT-VC)</h2>
          <.simple_form for={:issue} phx-submit="sign_vc" class="grid md:grid-cols-2 gap-4 mt-4">
            <.input name="issuer_did" value={@issuer_did} label="Issuer DID" placeholder="did:web:dmv.example.gov" />
            <.input name="issuer_kid" value={@issuer_kid} label="kid (defaults to #key-1)" placeholder="did:web:dmv.example.gov#key-2" />
            <.input type="select" name="issue_alg" value={@issue_alg} label="Algorithm" options={["ES256", "EdDSA"]} />
            <.input name="valid_days" value={@valid_days} label="Validity (days)" />
            <.input name="holder_did" value={@holder_did} label="Holder DID (subject)" />
            <.input name="name" value={@name} label="Holder Name" />
            <.input name="license" value={@license} label="License #" />
            <.input name="status_url" value={@status_url} label="StatusList2021 URL (optional)" />
            <.input name="status_idx" value={@status_idx} label="StatusListIndex (optional)" />
            <div class="md:col-span-2">
              <label class="text-sm font-medium">Issuer Private JWK (JSON)</label>
              <textarea name="issuer_priv_jwk" class="mt-1 w-full h-40 font-mono text-xs border rounded-lg p-2" placeholder='{"kty":"EC","crv":"P-256","d":"...","x":"...","y":"..."}'><%= @issuer_priv_jwk %></textarea>
            </div>
            <:actions>
              <.button class="mt-2">Sign VC</.button>
            </:actions>
          </.simple_form>

          <div class="mt-4">
            <p class="font-semibold">JWT-VC</p>
            <textarea class="w-full h-32 font-mono text-xs border rounded-lg p-2"><%= @vc_jwt %></textarea>
          </div>
        </div>
      <% end %>

      <!-- VERIFICATION -->
      <%= if @tab == :verify do %>
        <div class="mt-6 rounded-2xl border p-4 bg-white">
          <h2 class="font-semibold text-lg">Verify VC/VP (JWT)</h2>
          <.simple_form for={:verify} phx-submit="verify" class="grid md:grid-cols-2 gap-4 mt-4">
            <div class="md:col-span-2">
              <label class="text-sm font-medium">JWT</label>
              <textarea name="verify_jwt" class="mt-1 w-full h-32 font-mono text-xs border rounded-lg p-2" placeholder="Paste a JWT..."><%= @verify_jwt %></textarea>
            </div>
            <.input name="verify_aud" value={@verify_aud} label="expected aud (for VP)" placeholder="https://verifier.example/app" />
            <.input name="verify_nonce" value={@verify_nonce} label="expected nonce (for VP)" placeholder="challenge-123" />
            <:actions>
              <.button class="mt-2">Verify</.button>
            </:actions>
          </.simple_form>

          <div class="mt-4 flex items-center gap-3">
            <span class="font-semibold"><%= @verify_result %></span>
            <span class="text-xs text-slate-500"><%= @verify_log %></span>
          </div>

          <div class="mt-3">
            <p class="text-sm font-semibold">Decoded Verified Payload</p>
            <textarea class="w-full h-56 font-mono text-xs border rounded-lg p-2"><%= @verified_payload_json %></textarea>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------- Helpers ----------

  defp json(map), do: Jason.encode!(map, pretty: true)

  defp nonempty("", label), do: {:error, "#{label} is required"}
  defp nonempty(_, _), do: :ok

  defp to_int(s, default) when is_integer(s), do: s

  defp to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> default
    end
  end

  defp present(""), do: nil
  defp present(v), do: v

  defp did_from_host_path(host, ""), do: "did:web:" <> host

  defp did_from_host_path(host, path) do
    "did:web:" <> host <> ":" <> (path |> String.split("/", trim: true) |> Enum.join(":"))
  end

  defp did_web_url("did:web:" <> rest) do
    case String.split(rest, ":") do
      [host] -> "https://#{host}/.well-known/did.json"
      [host | path] -> "https://#{host}/#{Enum.join(path, "/")}/did.json"
    end
  end

  defp to_pub_priv(jwk) do
    {m, _} = JWK.to_map(jwk)
    pub = Map.drop(m, ["d"])
    {pub, m}
  end

  # ---------- Verification core ----------

  defp verify_token("", _opts), do: {:error, "empty token", %{}}

  defp verify_token(compact, opts) do
    with {:ok, header, payload} <- peek(compact),
         {:ok, type} <- token_type(payload),
         kid when is_binary(kid) <- Map.get(header, "kid") || raise("missing kid"),
         alg when is_binary(alg) <- Map.get(header, "alg") || raise("missing alg"),
         iss when is_binary(iss) <- Map.get(payload, "iss") || raise("missing iss"),
         true <- String.split(kid, "#") |> hd() == iss || raise("kid/iss mismatch"),
         {:ok, did_doc} <- resolve_did(iss),
         :ok <- enforce_relationship(did_doc, kid, type),
         {:ok, jwk_map} <- jwk_for_kid(did_doc, kid),
         jwk <- JWK.from_map(jwk_map),
         {:ok, {true, jwt_payload}} <- verify_sig_and_claims(jwk, alg, compact),
         :ok <- vp_bindings_ok?(type, jwt_payload, opts),
         :ok <- maybe_status_ok?(type, jwt_payload) do
      {:ok, %{type: type, payload: jwt_payload}}
    else
      %RuntimeError{message: msg} -> {:error, msg, %{}}
      {:error, msg} -> {:error, msg, %{}}
      other -> {:error, inspect(other), %{}}
    end
  rescue
    e -> {:error, Exception.message(e), %{}}
  end

  defp peek(compact) do
    case String.split(compact, ".", parts: 3) do
      [h, p, _s] ->
        with {:ok, header} <- b64json(h),
             {:ok, payload} <- b64json(p) do
          {:ok, header, payload}
        end

      _ ->
        {:error, "malformed JWS"}
    end
  end

  defp b64json(seg) do
    seg
    |> pad_base64()
    |> Base.url_decode64()
    |> case do
      {:ok, bin} -> Jason.decode(bin)
      _ -> {:error, "base64/json decode error"}
    end
  end

  defp pad_base64(s) do
    s <> String.duplicate("=", rem(4 - rem(byte_size(s), 4), 4))
  end

  defp token_type(payload) do
    cond do
      Map.has_key?(payload, "vp") -> {:ok, :vp}
      Map.has_key?(payload, "vc") -> {:ok, :vc}
      true -> {:error, "unrecognized token (no vc/vp claim)"}
    end
  end

  defp resolve_did(did = "did:web:" <> rest) do
    url =
      case String.split(rest, ":") do
        [host] -> "https://#{host}/.well-known/did.json"
        [host | path] -> "https://#{host}/#{Enum.join(path, "/")}/did.json"
      end

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_v, 200, _}, _h, body}} -> Jason.decode(body)
      {:ok, {{_v, code, _}, _h, _b}} -> {:error, "HTTP #{code} resolving DID"}
      {:error, reason} -> {:error, "resolve error: #{inspect(reason)}"}
    end
  end

  defp enforce_relationship(doc, kid, :vp) do
    auth = Map.get(doc, "authentication", [])
    if kid in auth, do: :ok, else: {:error, "kid not authorized for authentication"}
  end

  defp enforce_relationship(doc, kid, :vc) do
    am = Map.get(doc, "assertionMethod", [])
    if kid in am, do: :ok, else: {:error, "kid not authorized for assertionMethod"}
  end

  defp jwk_for_kid(doc, kid) do
    vm = doc |> Map.get("verificationMethod", []) |> Enum.find(&(&1["id"] == kid))

    case vm do
      %{"publicKeyJwk" => jwk} -> {:ok, jwk}
      _ -> {:error, "verificationMethod not found for kid"}
    end
  end

  defp verify_sig_and_claims(jwk, alg, compact) do
    case JWS.verify_strict(jwk, [alg], compact) do
      {true, payload_bin, _jws} ->
        with {:ok, payload} <- Jason.decode(payload_bin),
             :ok <- validate_times(payload) do
          {:ok, {true, payload}}
        else
          {:error, e} -> {:error, "payload decode: #{inspect(e)}"}
          {:error_msg, msg} -> {:error, msg}
        end

      _ ->
        {:error, "signature verification failed"}
    end
  end

  defp validate_times(%{"exp" => exp} = payload) when is_integer(exp) do
    now = System.os_time(:second)

    cond do
      (payload["nbf"] || 0) > now + 30 -> {:error_msg, "nbf in future"}
      exp < now - 30 -> {:error_msg, "token expired"}
      true -> :ok
    end
  end

  defp validate_times(_), do: :ok

  defp vp_bindings_ok?(:vp, payload, opts) do
    aud_opt = Keyword.get(opts, :aud)
    nonce_opt = Keyword.get(opts, :nonce)
    aud_claim = payload["aud"]
    nonce_claim = payload["nonce"]

    cond do
      is_binary(aud_opt) and aud_claim != aud_opt ->
        {:error, "aud mismatch"}

      is_binary(nonce_opt) and nonce_claim != nonce_opt ->
        {:error, "nonce mismatch"}

      true ->
        :ok
    end
  end

  defp vp_bindings_ok?(:vc, _payload, _opts), do: :ok

  defp maybe_status_ok?(:vc, %{"vc" => %{"credentialStatus" => cs}}) when is_map(cs) do
    case check_status_list_2021(cs) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, "credential revoked"}
      {:error, reason} -> {:error, "status check failed: #{reason}"}
    end
  end

  defp maybe_status_ok?(_, _), do: :ok

  # StatusList2021 (gzip+base64url bitstring; MSB-first)
  defp check_status_list_2021(%{
         "statusListCredential" => url,
         "statusListIndex" => idx_str
       }) do
    with {idx, ""} <- Integer.parse(idx_str),
         {:ok, vc} <- fetch_json(url),
         enc when is_binary(enc) <- get_in(vc, ["credentialSubject", "encodedList"]) || "",
         {:ok, zipped} <- Base.url_decode64(enc, padding: false),
         {:ok, bytes} <- gunzip(zipped),
         <<_::binary>> = data <- bytes do
      byte_index = div(idx, 8)
      bit_index = rem(idx, 8)
      byte = :binary.at(data, byte_index)

      # MSB-first per spec
      is_revoked = (byte >>> (7 - bit_index) &&& 1) == 1
      {:ok, !is_revoked}
    else
      :error -> {:error, "invalid statusListIndex"}
      {:error, reason} -> {:error, reason}
      nil -> {:error, "encodedList missing"}
      _ -> {:error, "status parse error"}
    end
  end

  defp fetch_json(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_v, 200, _}, _h, body}} -> Jason.decode(body)
      {:ok, {{_v, code, _}, _h, _b}} -> {:error, "HTTP #{code} for status list"}
      {:error, reason} -> {:error, "status fetch error: #{inspect(reason)}"}
    end
  end

  defp gunzip(bin) do
    try do
      {:ok, :zlib.gunzip(bin)}
    rescue
      _ -> {:error, "gunzip failed"}
    end
  end
end
