defmodule CodexPooler.Admin.PoolRecoveryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture()
    %{api_key: key, raw_key: raw_key} = api_key_fixture(pool, %{scope: scope})
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{owner: owner, scope: scope, pool: pool, key: key, raw_key: raw_key, assignment: assignment}
  end

  for status <- ["disabled", "archived"] do
    test "owner can edit and restore a #{status} pool without rotating its key", context do
      %{scope: scope, pool: pool, key: key, raw_key: raw_key, assignment: assignment} = context
      assert {:ok, inactive} = Pools.change_pool_status(scope, pool, unquote(status))
      assert {:error, %{code: :pool_inactive}} = Access.authenticate_api_key(raw_key)

      attrs = %{
        "name" => "Recovered pool",
        "status" => unquote(status),
        "routing_strategy" => "quota_first",
        "upstream_assignment_ids" => [assignment.id],
        "api_key_ids" => [key.id]
      }

      assert {:ok, edited} =
               PoolWorkflow.update_pool_with_related_settings(scope, inactive.id, attrs)

      assert edited.status == unquote(status)
      assert Pools.get_routing_settings(edited).routing_strategy == "quota_first"
      assert {:error, %{code: :pool_inactive}} = Access.authenticate_v1_api_key(raw_key)

      assert {:ok, restored} =
               PoolWorkflow.update_pool_with_related_settings(
                 scope,
                 edited.id,
                 Map.put(attrs, "status", "active")
               )

      assert restored.status == "active"
      assert [%{id: assignment_id, status: "active"}] = Upstreams.list_pool_assignments(restored)
      assert assignment_id == assignment.id
      assert Repo.get!(APIKey, key.id).key_hash == key.key_hash
      assert {:ok, %{pool_id: pool_id}} = Access.authenticate_api_key(raw_key)
      assert pool_id == pool.id
    end

    test "owner can move a #{status} pool's existing key to an active pool", context do
      %{scope: scope, pool: pool, key: key, raw_key: raw_key} = context

      assert {:ok, _} =
               Access.update_api_key_with_policy(scope, key, %{
                 maximum_reasoning_effort: "high",
                 default_policy: %{max_requests_per_minute: 9}
               })

      assert {:ok, _} = Pools.change_pool_status(scope, pool, unquote(status))
      assert {:ok, keys} = Access.list_api_keys(scope)
      assert Enum.any?(keys, &(&1.id == key.id))
      assert {:ok, [_]} = Access.list_api_keys(scope, pool.id)

      assert {:ok, target} =
               PoolWorkflow.create_pool_with_related_settings(scope, %{
                 "name" => "Replacement pool",
                 "api_key_ids" => [key.id]
               })

      assert Pools.get_pool(pool.id).status == unquote(status)

      assert {:ok, %{api_key: moved, policy_bindings: [binding]}} =
               Access.get_api_key_with_policy(scope, key.id)

      assert moved.pool_id == target.id
      assert moved.key_hash == key.key_hash
      assert moved.maximum_reasoning_effort == "high"
      assert binding.max_requests_per_minute == 9
      assert {:ok, %{pool_id: target_id}} = Access.authenticate_api_key(raw_key)
      assert target_id == target.id
    end
  end

  test "failed restoration rolls back status and related settings", context do
    %{scope: scope, pool: pool} = context
    assert {:ok, inactive} = Pools.change_pool_status(scope, pool, "disabled")

    assert {:error, %{message: "selected API keys are not available"}} =
             PoolWorkflow.update_pool_with_related_settings(scope, inactive, %{
               "name" => "Must roll back",
               "status" => "active",
               "api_key_ids" => [Ecto.UUID.generate()]
             })

    assert Pools.get_pool(pool.id).status == "disabled"
    assert Pools.get_pool(pool.id).name == pool.name
  end

  test "assigned admins cannot recover inactive pools or their keys", context do
    %{scope: scope, owner: owner, pool: pool, key: key} = context
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)
    assert {:ok, inactive} = Pools.change_pool_status(scope, pool, "disabled")

    assert {:ok, []} = Access.list_api_keys(admin_scope)
    assert {:error, _} = Access.get_api_key(admin_scope, key.id)
    assert {:error, _} = Access.list_api_keys(admin_scope, pool.id)

    assert {:error, _} =
             PoolWorkflow.update_pool_with_related_settings(admin_scope, inactive, %{
               "name" => "Denied",
               "status" => "active",
               "api_key_ids" => [key.id]
             })

    assert Pools.get_pool(pool.id).status == "disabled"
    assert Repo.get!(APIKey, key.id).pool_id == pool.id
  end
end
