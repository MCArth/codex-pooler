defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  test "overlapping distinct requests wait for their shared turn" do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    on_exit(fn ->
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    release = make_ref()

    terminal =
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_overlap",
           "status" => "completed",
           "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
         }
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream([terminal],
             barrier_after: 0,
             notify: self(),
             release_ref: release
           ),
           FakeUpstream.sse_stream([terminal])
         ]}
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = Ecto.UUID.generate()
    turn_id = Ecto.UUID.generate()
    first = start_client(port, setup, turn_state, turn_id, "first")
    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release}, 5_000
    second = start_client(port, setup, turn_state, turn_id, "second")

    try do
      wait_for_accepted(setup.pool.id, 100)

      assert Task.yield(second, 200) == nil
      assert FakeUpstream.count(upstream) == 1
    after
      send(upstream_pid, {:fake_upstream_release_chunk, release})
    end

    assert %{"type" => "response.completed"} = Task.await(first, 10_000)
    assert %{"type" => "response.completed"} = Task.await(second, 10_000)
    assert FakeUpstream.count(upstream) == 2

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "succeeded"),
             :count
           ) == 2
  end

  defp start_client(port, setup, turn_state, turn_id, text) do
    Task.async(fn ->
      {conn, ws, ref} = public_websocket_connect!(port, setup, turn_state)

      try do
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, payload(setup, turn_id, text))
        {_conn, _ws, terminal} = public_websocket_receive_text!(conn, ws, ref)
        CodexPooler.JSON.decode!(terminal)
      after
        Mint.HTTP.close(conn)
      end
    end)
  end

  defp wait_for_accepted(_pool_id, 0), do: flunk("second request was not accepted")

  defp wait_for_accepted(pool_id, remaining) do
    if Repo.exists?(from r in Request, where: r.pool_id == ^pool_id and r.status == "accepted") do
      :ok
    else
      Process.sleep(20)
      wait_for_accepted(pool_id, remaining - 1)
    end
  end

  for owner_forwarding <- [false, true], reconnect <- [false, true] do
    @tag owner_forwarding: owner_forwarding, reconnect: reconnect
    test "completion commits before a same-turn continuation reconnects (owner=#{owner_forwarding}, reconnect=#{reconnect})",
         %{owner_forwarding: owner_forwarding, reconnect: reconnect} do
      previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, owner_forwarding)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled),
          else: Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
      end)

      upstream =
        start_upstream(
          FakeUpstream.websocket_text_frames([
            CodexPooler.JSON.encode!(%{
              "type" => "response.output_text.delta",
              "delta" => "streaming"
            }),
            CodexPooler.JSON.encode!(%{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_continuation_barrier",
                "status" => "completed",
                "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
              }
            })
          ])
        )

      setup = gateway_setup(upstream)
      port = start_public_endpoint!()
      test_pid = self()
      barrier = make_ref()
      once = :atomics.new(1, [])
      handler = {__MODULE__, barrier}

      :ok =
        :telemetry.attach(
          handler,
          [:codex_pooler, :repo, :query],
          &__MODULE__.hold_settlement/4,
          {test_pid, barrier, once}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      client =
        Task.async(fn ->
          turn_state = Ecto.UUID.generate()
          turn_id = Ecto.UUID.generate()
          {conn, ws, ref} = public_websocket_connect!(port, setup, turn_state)

          {conn, ws} =
            public_websocket_send_text!(conn, ws, ref, payload(setup, turn_id, "first"))

          {conn, ws, delta} = public_websocket_receive_text!(conn, ws, ref)
          assert %{"type" => "response.output_text.delta"} = CodexPooler.JSON.decode!(delta)
          send(test_pid, {barrier, :delta})
          {conn, ws, terminal} = public_websocket_receive_text!(conn, ws, ref)
          assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(terminal)
          send(test_pid, {barrier, :terminal})

          {conn, ws, ref} =
            if reconnect do
              Mint.HTTP.close(conn)
              public_websocket_connect!(port, setup, turn_state)
            else
              {conn, ws, ref}
            end

          try do
            {conn, ws} =
              public_websocket_send_text!(conn, ws, ref, payload(setup, turn_id, "follow-up"))

            {conn, ws, delta} = public_websocket_receive_text!(conn, ws, ref)
            assert %{"type" => "response.output_text.delta"} = CodexPooler.JSON.decode!(delta)
            {_conn, _ws, terminal} = public_websocket_receive_text!(conn, ws, ref)
            assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(terminal)
          after
            Mint.HTTP.close(conn)
          end
        end)

      assert_receive {^barrier, :delta}, 5_000
      assert_receive {^barrier, :settlement, settlement_pid}, 5_000

      try do
        refute_receive {^barrier, :terminal}, 150
      after
        send(settlement_pid, {barrier, :release})
      end

      Task.await(client, 10_000)

      requests = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
      assert length(requests) == 2
      assert Enum.all?(requests, &(&1.status == "succeeded" and &1.transport == "websocket"))
      turns = Repo.all(from t in CodexTurn, where: t.request_id in ^Enum.map(requests, & &1.id))
      assert length(turns) == 2
      assert Enum.all?(turns, &(&1.status == "succeeded"))
      assert length(Enum.uniq_by(turns, & &1.semantic_turn_digest)) == 1
      assert FakeUpstream.count(upstream) == 2
    end
  end

  def hold_settlement(_event, _measurements, metadata, {test_pid, barrier, once}) do
    if String.starts_with?(metadata.query, "UPDATE \"requests\"") and
         "succeeded" in metadata.params and :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      send(test_pid, {barrier, :settlement, self()})

      receive do
        {^barrier, :release} -> :ok
      after
        5_000 -> raise "settlement barrier was not released"
      end
    end
  end

  defp payload(setup, turn_id, text) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" =>
        native_text_input("continue") ++
          [
            %{
              "type" => "function_call_output",
              "call_id" => "call_continuation",
              "output" => text
            }
          ],
      "stream" => true,
      "generate" => true,
      "client_metadata" => %{
        "x-codex-turn-metadata" => %{
          "turn_id" => turn_id,
          "request_kind" => "turn"
        }
      }
    })
  end
end
