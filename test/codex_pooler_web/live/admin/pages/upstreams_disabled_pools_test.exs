defmodule CodexPoolerWeb.Admin.UpstreamsDisabledPoolsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel

  setup :register_and_log_in_user

  test "disabled-only accounts appear only under Disabled, including after filter changes", %{
    conn: conn
  } do
    active = pool_fixture(%{name: "Enabled pool"})
    disabled = pool_fixture(%{name: "Disabled pool", status: "disabled"})
    archived = pool_fixture(%{status: "archived"})
    %{identity: enabled} = upstream_assignment_fixture(active)
    %{identity: inactive} = upstream_assignment_fixture(disabled, %{account_label: "Dormant"})
    %{identity: paused} = upstream_assignment_fixture(disabled, %{identity_status: "paused"})

    %{identity: explicitly_disabled} =
      upstream_assignment_fixture(active, %{identity_status: "disabled"})

    %{identity: archived_identity} = upstream_assignment_fixture(archived)

    %{identity: deleted_identity} =
      upstream_assignment_fixture(disabled, %{identity_status: "deleted"})

    %{identity: deleted_assignment} =
      upstream_assignment_fixture(disabled, %{assignment_status: "deleted"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    assert has_element?(view, "#upstream-account-#{enabled.id}")
    refute has_element?(view, "#upstream-account-#{inactive.id}")
    refute has_element?(view, "#upstream-account-#{paused.id}")

    view |> element("#upstream-status-filter button[data-status='disabled']") |> render_click()
    assert_patch(view, ~p"/admin/upstreams?status=disabled")

    for identity <- [inactive, paused, explicitly_disabled] do
      assert has_element?(view, "#upstream-account-#{identity.id}")
    end

    for identity <- [enabled, archived_identity, deleted_identity, deleted_assignment] do
      refute has_element?(view, "#upstream-account-#{identity.id}")
    end

    view
    |> element("#upstream-filter-form")
    |> render_change(%{
      "filters" => %{"query" => "Dormant", "status" => "disabled", "pool_id" => ""}
    })

    assert has_element?(view, "#upstream-account-#{inactive.id}")
    refute has_element?(view, "#upstream-account-#{paused.id}")
    view |> element("#upstream-filter-query-clear") |> render_click()

    view
    |> element("#upstream-pool-filter button[data-pool-id='#{disabled.id}']")
    |> render_click()

    assert has_element?(view, "#upstream-account-#{inactive.id}")
    refute has_element?(view, "#upstream-account-#{explicitly_disabled.id}")

    view |> element("#upstream-status-filter button[data-status='']") |> render_click()
    assert has_element?(view, "#filters_pool_id[value='']")
    assert has_element?(view, "#upstream-account-#{enabled.id}")
    refute has_element?(view, "#upstream-account-#{inactive.id}")

    for status <- ["active", "paused", "refresh_due", "reauth_required"] do
      {:ok, filtered, _html} = live(conn, ~p"/admin/upstreams?status=#{status}")
      refute has_element?(filtered, "#upstream-account-#{inactive.id}")
      refute has_element?(filtered, "#upstream-account-#{paused.id}")
    end

    {:ok, direct, _html} =
      live(conn, ~p"/admin/upstreams?pool_id=#{disabled.id}&status=disabled")

    assert has_element?(direct, "#filters_pool_id[value='#{disabled.id}']")
    assert has_element?(direct, "#upstream-account-#{inactive.id}")

    assert {:ok, _detail, _html} = live(conn, ~p"/admin/upstreams/#{inactive.id}")
  end

  test "an enabled-pool assignment prevents disabled-only classification across pool filters", %{
    scope: scope
  } do
    active = pool_fixture()
    disabled = pool_fixture(%{status: "disabled"})
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(disabled)

    active_assignment =
      assignment
      |> Map.from_struct()
      |> Map.drop([:id, :__meta__])
      |> Map.put(:pool_id, active.id)
      |> then(&struct!(assignment.__struct__, &1))
      |> Repo.insert!()

    assert [] ==
             UpstreamAccountsReadModel.list_visible_accounts(scope, [disabled], %{
               "status" => "disabled"
             })

    active_assignment |> Ecto.Changeset.change(status: "deleted") |> Repo.update!()

    assert [%{identity: %{id: identity_id}}] =
             UpstreamAccountsReadModel.list_visible_accounts(scope, [disabled], %{
               "status" => "disabled"
             })

    assert identity_id == identity.id
  end

  test "disabled pool visibility remains restricted to assigned pools", %{scope: owner_scope} do
    visible = pool_fixture(%{status: "disabled"})
    hidden = pool_fixture(%{status: "disabled"})
    %{identity: visible_identity} = upstream_assignment_fixture(visible)
    %{identity: hidden_identity} = upstream_assignment_fixture(hidden)

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible, created_by_user_id: owner_scope.user.id)

    accounts =
      UpstreamAccountsReadModel.list_visible_accounts(Scope.for_user(admin), [visible, hidden], %{
        "status" => "disabled"
      })

    assert Enum.map(accounts, & &1.identity.id) == [visible_identity.id]
    refute inspect(accounts) =~ hidden_identity.id
    assert [] == UpstreamAccountsReadModel.list_visible_accounts(Scope.for_user(admin), [visible])

    assert {:ok, _cockpit} =
             UpstreamCockpitReadModel.load_visible(Scope.for_user(admin), visible_identity.id)

    assert :error =
             UpstreamCockpitReadModel.load_visible(Scope.for_user(admin), hidden_identity.id)
  end
end
