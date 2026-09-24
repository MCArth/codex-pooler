defmodule CodexPooler.Catalog.ClientVersionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.ClientVersion
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.CodexClientIdentity

  test "persists the newest client version without downgrades or cross-pool changes" do
    pool = pool_fixture()
    other = pool_fixture()
    assert :ok = ClientVersion.observe(pool, "1.12.0-alpha.9.2")
    assert :ok = ClientVersion.observe(pool, "1.9.0")
    assert :ok = ClientVersion.observe(pool, "1.12.0")
    assert Repo.get!(Pool, pool.id).catalog_client_version == "1.12.0"
    assert ClientVersion.for_pool(Repo.get!(Pool, pool.id)) == "1.12.0"
    assert Repo.get!(Pool, other.id).catalog_client_version == nil
    assert [%{args: %{"pool_id" => pool_id}}] = all_enqueued(worker: CatalogSyncWorker)
    assert pool_id == pool.id
  end

  test "malformed and older versions neither write nor enqueue" do
    pool = pool_fixture()

    for value <- [nil, "", "not-a-version", "999999999999.0.0", "1.2.3\r\ninjected", %{}, "0.0.1"] do
      assert :ok = ClientVersion.observe(pool, value)
    end

    assert Repo.get!(Pool, pool.id).catalog_client_version == nil
    assert all_enqueued(worker: CatalogSyncWorker) == []
  end

  test "an executing sync does not swallow an upgrade refresh" do
    pool = pool_fixture()
    assert :ok = ClientVersion.observe(pool, "1.0.0")
    [job] = all_enqueued(worker: CatalogSyncWorker)
    job |> Ecto.Changeset.change(state: "executing") |> Repo.update!()
    assert :ok = ClientVersion.observe(pool, "1.1.0")
    assert [%{id: next_id}] = all_enqueued(worker: CatalogSyncWorker)
    refute next_id == job.id
  end

  test "scheduled discovery uses the stored version in both query and headers" do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams.Secrets)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams.Secrets,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, CodexPooler.Upstreams.Secrets, previous),
        else: Application.delete_env(:codex_pooler, CodexPooler.Upstreams.Secrets)
    end)

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.json_response(%{"models" => [%{"slug" => "future-model"}]})
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    pool = pool_fixture()

    active_upstream_assignment_fixture(pool,
      metadata: %{"base_url" => FakeUpstream.url(upstream)}
    )

    assert :ok = ClientVersion.observe(pool, "1.2.3-alpha.1")

    assert {:ok, %{models: [_model]}} =
             Catalog.sync_pool_catalog(pool.id, trigger_kind: "scheduled")

    [request] = FakeUpstream.requests(upstream)
    assert URI.decode_query(request.query_string)["client_version"] == "1.2.3"
    assert Map.new(request.headers)["version"] == "1.2.3"
    assert Map.new(request.headers)["user-agent"] == CodexClientIdentity.user_agent()
  end
end
