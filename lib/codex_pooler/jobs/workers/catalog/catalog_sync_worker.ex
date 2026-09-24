defmodule CodexPooler.Jobs.CatalogSyncWorker do
  @moduledoc """
  Synchronizes the model catalog for one pool.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["catalog_sync"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:pool_id],
      states: :incomplete,
      period: {7, :days}
    ]

  alias CodexPooler.Catalog.JobWorkflow

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pool_id" => pool_id} = args}) do
    trigger_kind = Map.get(args, "trigger_kind", "scheduled")

    case JobWorkflow.sync_catalog(pool_id, trigger_kind) do
      {:ok, _result} -> :ok
      {:error, %{code: :catalog_sync_in_progress}} -> {:snooze, 30}
      {:error, reason} -> {:error, reason}
    end
  end
end
