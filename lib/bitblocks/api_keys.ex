defmodule Bitblocks.ApiKeys do
  @moduledoc """
  API keys: a caller's own rate budget (#12, #13, #29 step 5).

  A key is `bbk_` plus 32 random bytes (base64url). Only its sha256 is stored;
  `create/3` returns the key once. `BitblocksWeb.Plugs.RateLimiter` counts a
  keyed request against the key's `requests_per_minute`, not the caller's IP.

  Lookups are cached in ETS for #{60} seconds, so a revoked key stops working
  within a minute on every node.

  A key can also hold scopes (#50). A new key has none, and neither does an
  existing one: `ops_read` is only ever granted by name, at creation or with
  `grant_scope/2`, and `BitblocksWeb.Plugs.RequireScope` refuses everyone else.

  A signed-in user can take one trial key from `/start` (#59), with a small
  budget and no scopes. Replacing it revokes the old one.

  A wallet or agent can take one by signing a bitblocks challenge instead
  (#121): `challenge_message/3` is the text it signs as a Bitcoin Signed
  Message, and `issue_signed/3` recovers the address from the signature and
  binds the key to it, one active key per address, each challenge once. The
  web layer issues and checks the challenge itself (`BitblocksWeb.Api.KeyController`).
  """

  import Ecto.Query

  alias Bitblocks.Accounts.User
  alias Bitblocks.Aip
  alias Bitblocks.ApiKeys.ApiKey
  alias Bitblocks.Repo

  @cache :api_key_cache
  @cache_ttl_ms 60_000
  @trial_requests_per_minute 60
  @challenge_max_age_s 300

  @doc """
  Creates a key. Returns `{:ok, %ApiKey{}, token}`; the token isn't stored.
  Options: `:scopes`, none by default; `:user_id`, the key's owner; and
  `:address` and `:challenge_nonce`, for a key taken by signing.
  """
  @spec create(String.t(), pos_integer(), keyword()) ::
          {:ok, ApiKey.t(), String.t()} | {:error, term()}
  def create(name, requests_per_minute, opts \\ []) do
    token = "bbk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %ApiKey{}
    |> ApiKey.changeset(%{
      name: name,
      requests_per_minute: requests_per_minute,
      token_hash: hash(token),
      prefix: String.slice(token, 0, 12),
      scopes: Keyword.get(opts, :scopes, []),
      user_id: Keyword.get(opts, :user_id),
      address: Keyword.get(opts, :address),
      challenge_nonce: Keyword.get(opts, :challenge_nonce)
    })
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key, token}
      error -> error
    end
  end

  @doc "Requests a minute on a trial key."
  def trial_requests_per_minute, do: @trial_requests_per_minute

  @doc "The user's active trial key, or nil."
  @spec trial_key(User.t()) :: ApiKey.t() | nil
  def trial_key(%User{id: id}) do
    Repo.one(from k in ApiKey, where: k.user_id == ^id and is_nil(k.revoked_at))
  end

  @doc """
  Issues the user's key. Returns `{:ok, %ApiKey{}, token}`, or an error
  changeset when they already hold one. It gets the trial's budget, or their
  monthly plan's while they have one (`Bitblocks.Billing`,
  https://github.com/afomi/bitblocks/issues/112), so a replaced key keeps it.
  """
  @spec issue_trial(User.t()) :: {:ok, ApiKey.t(), String.t()} | {:error, term()}
  def issue_trial(%User{} = user) do
    create("trial:#{user.login}", Bitblocks.Billing.key_requests_per_minute(user),
      user_id: user.id
    )
  end

  @doc """
  This node forgets the cached lookups of every key the user owns, so a
  changed limit counts from their next request; other nodes within the TTL.
  """
  @spec forget_user_keys(integer()) :: :ok
  def forget_user_keys(user_id) when is_integer(user_id) do
    ensure_cache()

    from(k in ApiKey, where: k.user_id == ^user_id, select: k.token_hash)
    |> Repo.all()
    |> Enum.each(&:ets.delete(@cache, &1))
  end

  @doc "Revokes the user's trial key, if any, and issues a new one."
  @spec replace_trial(User.t()) :: {:ok, ApiKey.t(), String.t()} | {:error, term()}
  def replace_trial(%User{} = user) do
    if key = trial_key(user), do: revoke(key.id)
    issue_trial(user)
  end

  @doc "How long a signing challenge is good for, in seconds."
  @spec challenge_max_age_s() :: pos_integer()
  def challenge_max_age_s, do: @challenge_max_age_s

  @doc "When a challenge issued at `issued_at` expires."
  @spec challenge_expires_at(DateTime.t()) :: DateTime.t()
  def challenge_expires_at(%DateTime{} = issued_at),
    do: DateTime.add(issued_at, @challenge_max_age_s)

  @doc """
  The text a wallet signs for a key: the site, a one-time nonce, when it was
  issued and when it expires, one per line, no trailing newline, plain UTF-8.
  The caller signs it exactly.

  `Expires:` is there so a wallet can show the deadline before signing. It is
  derived from `Issued:`, so the server rebuilds the same text from the
  challenge token, and still enforces the expiry from the token itself.
  """
  @spec challenge_message(String.t(), String.t(), DateTime.t()) :: String.t()
  def challenge_message(site, nonce, %DateTime{} = issued_at) do
    Enum.join(
      [
        "Sign this to get a bitblocks API key bound to your key.",
        "Site: #{site}",
        "Nonce: #{nonce}",
        "Issued: #{DateTime.to_iso8601(issued_at)}",
        "Expires: #{issued_at |> challenge_expires_at() |> DateTime.to_iso8601()}"
      ],
      "\n"
    )
  end

  @doc """
  Issues a key bound to whoever signed `message` (a `challenge_message/3`),
  revoking any key that address already holds. The caller has checked that
  bitblocks issued the challenge and that it's fresh; `nonce` is its nonce,
  and a nonce redeemed before is `{:error, :challenge_used}`.

  Options: `:address`, when the caller says who it expects; a signature from
  anyone else is `{:error, {:wrong_signer, recovered}}`.
  """
  @spec issue_signed(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, ApiKey.t(), String.t()}
          | {:error, :bad_signature | :challenge_used | :conflict | {:wrong_signer, String.t()}}
  def issue_signed(message, signature, nonce, opts \\ []) do
    with {:ok, address} <- signer_address(message, signature),
         :ok <- expected_signer(address, Keyword.get(opts, :address)) do
      Repo.transaction(fn ->
        Repo.update_all(
          from(k in ApiKey, where: k.address == ^address and is_nil(k.revoked_at)),
          set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        case create("signed:" <> address, @trial_requests_per_minute,
               address: address,
               challenge_nonce: nonce
             ) do
          {:ok, key, token} -> {key, token}
          {:error, changeset} -> Repo.rollback(insert_error(changeset))
        end
      end)
      |> case do
        {:ok, {key, token}} ->
          forget_revoked(address, key.id)
          {:ok, key, token}

        error ->
          error
      end
    end
  end

  @doc "The address's active signed key, or nil."
  @spec signed_key(String.t()) :: ApiKey.t() | nil
  def signed_key(address) when is_binary(address) do
    Repo.one(from k in ApiKey, where: k.address == ^address and is_nil(k.revoked_at))
  end

  # The mainnet P2PKH address of the key the signature recovers to. Recovery
  # is the check: any well-formed signature recovers to *some* key, so a
  # signature over other text binds the key to an address nobody holds.
  # A caller that wants that caught sends the address it expects.
  defp signer_address(message, signature) do
    with {:ok, pubkey_hex} <- Aip.recover_pubkey(message, signature),
         {:ok, pubkey} <- Base.decode16(pubkey_hex, case: :lower) do
      {:ok, B58.encode58_check!(BSV.Hash.sha256_ripemd160(pubkey), <<0x00>>)}
    else
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :bad_signature}
  end

  defp expected_signer(_address, nil), do: :ok
  defp expected_signer(address, address), do: :ok
  defp expected_signer(address, _other), do: {:error, {:wrong_signer, address}}

  defp insert_error(changeset) do
    if Keyword.has_key?(changeset.errors, :challenge_nonce),
      do: :challenge_used,
      else: :conflict
  end

  # Revoked rows stop working on this node now, other nodes within the TTL.
  defp forget_revoked(address, keep_id) do
    ensure_cache()

    from(k in ApiKey, where: k.address == ^address and k.id != ^keep_id, select: k.token_hash)
    |> Repo.all()
    |> Enum.each(&:ets.delete(@cache, &1))
  end

  @doc """
  Registers a key made elsewhere from its sha256 (64 lowercase hex), so the
  token never passes through this node or an operator's output. The token
  must start `bbk_` and hold 32 random bytes, as `create/3` makes them.
  Option: `:scopes`, none by default.
  """
  @spec create_from_hash(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, ApiKey.t()} | {:error, term()}
  def create_from_hash(name, requests_per_minute, token_hash, opts \\ []) do
    if token_hash =~ ~r/\A[0-9a-f]{64}\z/ do
      %ApiKey{}
      |> ApiKey.changeset(%{
        name: name,
        requests_per_minute: requests_per_minute,
        token_hash: token_hash,
        prefix: "sha256:" <> String.slice(token_hash, 0, 5),
        scopes: Keyword.get(opts, :scopes, [])
      })
      |> Repo.insert()
    else
      {:error, :bad_hash}
    end
  end

  @doc "The active key for a token, or nil (unknown or revoked). Cached briefly."
  @spec verify(String.t()) :: ApiKey.t() | nil
  def verify(token) when is_binary(token) do
    digest = hash(token)
    now = System.monotonic_time(:millisecond)
    ensure_cache()

    case :ets.lookup(@cache, digest) do
      [{^digest, key, expires}] when expires > now ->
        key

      _ ->
        key =
          Repo.one(from k in ApiKey, where: k.token_hash == ^digest and is_nil(k.revoked_at))

        # Only hits are cached: caching misses would let random tokens grow the
        # table. Misses are throttled by the caller's IP budget instead.
        if key, do: :ets.insert(@cache, {digest, key, now + @cache_ttl_ms})
        key
    end
  end

  @doc "True when the key holds `scope`."
  @spec scope?(ApiKey.t(), String.t()) :: boolean()
  def scope?(%ApiKey{scopes: scopes}, scope), do: scope in scopes

  @doc """
  Grants a scope to a key by id. Other nodes see it within the cache TTL.
  An unknown scope is a changeset error.
  """
  @spec grant_scope(integer(), String.t()) :: {:ok, ApiKey.t()} | {:error, term()}
  def grant_scope(id, scope) do
    key = Repo.get!(ApiKey, id)

    result =
      key
      |> ApiKey.changeset(%{scopes: Enum.uniq([scope | key.scopes])})
      |> Repo.update()

    ensure_cache()
    :ets.delete(@cache, key.token_hash)
    result
  end

  @doc "Revokes a key by id."
  def revoke(id) do
    key = Repo.get!(ApiKey, id)

    result =
      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    # This node forgets it now; other nodes within the cache TTL.
    ensure_cache()
    :ets.delete(@cache, key.token_hash)
    result
  end

  @doc "All keys, newest first."
  def list, do: Repo.all(from k in ApiKey, order_by: [desc: k.id])

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "Creates the lookup cache at boot (see `Bitblocks.Application`)."
  def create_cache, do: ensure_cache()

  defp ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      try do
        :ets.new(@cache, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
