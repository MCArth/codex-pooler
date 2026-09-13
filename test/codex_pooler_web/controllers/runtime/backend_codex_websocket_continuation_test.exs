defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

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
