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
  """

  import Ecto.Query

  alias Bitblocks.ApiKeys.ApiKey
  alias Bitblocks.Repo

  @cache :api_key_cache
  @cache_ttl_ms 60_000

  @doc """
  Creates a key. Returns `{:ok, %ApiKey{}, token}`; the token isn't stored.
  Option: `:scopes`, none by default.
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
      scopes: Keyword.get(opts, :scopes, [])
    })
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key, token}
      error -> error
    end
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
