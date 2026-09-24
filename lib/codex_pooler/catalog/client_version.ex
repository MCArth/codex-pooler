defmodule CodexPooler.Catalog.ClientVersion do
  @moduledoc """
  Durable per-pool discovery version learned from authenticated Codex clients.
  """

  import Ecto.Query

  alias CodexPooler.Jobs
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.CodexClientIdentity

  @spec for_pool(Pool.t()) :: String.t()
  def for_pool(%Pool{catalog_client_version: version}),
    do: CodexClientIdentity.newest_version(version)

  @spec observe(Pool.t(), term()) :: :ok | {:error, term()}
  def observe(%Pool{} = pool, candidate) do
    version = CodexClientIdentity.normalise_version(candidate)

    if version && Version.compare(version, for_pool(pool)) == :gt do
      persist_and_enqueue(pool.id, version)
    else
      :ok
    end
  end

  defp persist_and_enqueue(pool_id, version) do
    Repo.transaction(fn ->
      {updated, _rows} =
        from(pool in Pool,
          where: pool.id == ^pool_id,
          where:
            is_nil(pool.catalog_client_version) or
              fragment(
                "string_to_array(?, '.')::int[] < string_to_array(?, '.')::int[]",
                pool.catalog_client_version,
                ^version
              )
        )
        |> Repo.update_all(set: [catalog_client_version: version])

      if updated == 1 do
        enqueue_refresh(pool_id)
      end
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_refresh(pool_id) do
    # An executing sync may have read the previous version; allow a queued successor.
    case Jobs.enqueue_catalog_sync(pool_id,
           trigger_kind: "reconcile",
           unique: [
             fields: [:args, :queue, :worker],
             keys: [:pool_id],
             states: [:available, :scheduled, :retryable],
             period: {7, :days}
           ]
         ) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
