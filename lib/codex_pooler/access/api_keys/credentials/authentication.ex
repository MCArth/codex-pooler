defmodule CodexPooler.Access.APIKeys.Authentication do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.{Errors, Material, TouchDebounce}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @status_active "active"
  @status_paused "paused"
  @status_revoked "revoked"

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type auth_context :: %{
          required(:api_key) => APIKey.t(),
          required(:pool) => Pool.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:key_prefix) => String.t()
        }

  @spec authenticate_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  def authenticate_api_key(raw_key) when is_binary(raw_key) do
    with {:ok, key_prefix, secret} <- Material.split(raw_key),
         %APIKey{} = api_key <- Repo.get_by(APIKey, key_prefix: key_prefix),
         :ok <- Material.verify(api_key.key_hash, secret),
         :ok <- ensure_api_key_usable(api_key),
         {:ok, pool} <- active_pool(api_key.pool_id) do
      {:ok, auth_context(touch_api_key!(api_key), pool)}
    else
      nil ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, :empty_api_key} ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, :invalid_api_key} ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      :invalid_secret ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, _reason} = error ->
        error
    end
  end

  def authenticate_api_key(_raw_key),
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  @spec authenticate_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  def authenticate_authorization_header("Bearer " <> raw_key), do: authenticate_api_key(raw_key)

  def authenticate_authorization_header(_header),
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  @spec authenticate_v1_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  def authenticate_v1_authorization_header("Bearer " <> raw_key),
    do: authenticate_v1_api_key(raw_key)

  def authenticate_v1_authorization_header(_header),
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  @spec authenticate_v1_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  def authenticate_v1_api_key(raw_key) when is_binary(raw_key) do
    with {:ok, key_prefix, secret} <- Material.split(raw_key),
         %APIKey{} = api_key <- Repo.get_by(APIKey, key_prefix: key_prefix),
         :ok <- Material.verify(api_key.key_hash, secret),
         :ok <- ensure_v1_api_key_usable(api_key),
         {:ok, pool} <- active_pool(api_key.pool_id) do
      {:ok, auth_context(touch_api_key!(api_key), pool)}
    else
      nil ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, :empty_api_key} ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, :invalid_api_key} ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      :invalid_secret ->
        {:error, Errors.access_error(:api_key_missing, "api key is required")}

      {:error, _reason} = error ->
        error
    end
  end

  def authenticate_v1_api_key(_raw_key),
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  @spec hash_api_key_secret(binary()) :: binary()
  def hash_api_key_secret(secret), do: Material.hash_secret(secret)

  defp auth_context(%APIKey{} = api_key, %Pool{} = pool) do
    %{
      api_key: api_key,
      pool: pool,
      api_key_id: api_key.id,
      pool_id: pool.id,
      key_prefix: api_key.key_prefix
    }
  end

  defp touch_api_key!(%APIKey{} = api_key), do: TouchDebounce.touch(api_key, now())

  defp active_pool(pool_id) do
    case Pools.get_active_pool(pool_id) do
      %Pool{} = pool ->
        {:ok, pool}

      nil ->
        {:error,
         Errors.access_error(
           :pool_inactive,
           "the API key's pool is disabled or archived; re-enable it or move the key to an active pool"
         )}
    end
  end

  defp ensure_api_key_usable(%APIKey{status: @status_revoked}),
    do: {:error, Errors.access_error(:api_key_revoked, "api key is revoked")}

  defp ensure_api_key_usable(%APIKey{status: @status_paused}),
    do: {:error, Errors.access_error(:api_key_paused, "api key is paused")}

  defp ensure_api_key_usable(%APIKey{status: status}) when status != @status_active,
    do: {:error, Errors.access_error(:api_key_inactive, "api key is inactive")}

  defp ensure_api_key_usable(%APIKey{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, now()) == :gt do
      :ok
    else
      {:error, Errors.access_error(:api_key_expired, "api key is expired")}
    end
  end

  defp ensure_api_key_usable(%APIKey{}), do: :ok

  defp ensure_v1_api_key_usable(%APIKey{status: @status_active} = api_key),
    do: ensure_api_key_usable(api_key)

  defp ensure_v1_api_key_usable(%APIKey{}),
    do: {:error, Errors.access_error(:api_key_disabled, "api key is disabled")}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
