defmodule Discord.Gateways.PubSubTest do
  use ExUnit.Case, async: false

  alias Discord.Gateways.PubSub

  setup_all do
    start_supervised!({PubSub, []})
    :ok
  end

  defp build_event(name, type, extra \\ %{}) do
    Map.merge(
      %{
        connection: name,
        type: type,
        seq: 1,
        received_at: "2026-05-14T00:00:00Z",
        data: %{}
      },
      extra
    )
  end

  test "subscribe/1 then broadcast delivers a :gateway_event message to the caller" do
    :ok = PubSub.subscribe("conn-a")
    event = build_event("conn-a", "MESSAGE_CREATE")
    :ok = PubSub.broadcast("conn-a", event)

    assert_receive {:gateway_event, ^event}, 100

    :ok = PubSub.unsubscribe("conn-a")
  end

  test "subscribe/1 accepts an atom name normalized to string" do
    :ok = PubSub.subscribe(:atomic)
    event = build_event("atomic", "READY")
    :ok = PubSub.broadcast(:atomic, event)

    assert_receive {:gateway_event, ^event}, 100

    :ok = PubSub.unsubscribe(:atomic)
  end

  test "broadcast with no subscribers does not crash and returns :ok" do
    # No subscribers at all on this topic.
    assert :ok = PubSub.broadcast("nobody-home", build_event("nobody-home", "READY"))
  end

  test "subscribe/2 by type does not deliver other event types" do
    :ok = PubSub.subscribe("filter-conn", "MESSAGE_CREATE")
    :ok = PubSub.broadcast("filter-conn", build_event("filter-conn", "READY"))

    refute_receive {:gateway_event, _}, 50

    :ok = PubSub.unsubscribe("filter-conn", "MESSAGE_CREATE")
  end

  test "subscribe/2 by type delivers matching events" do
    :ok = PubSub.subscribe("match-conn", "MESSAGE_CREATE")
    event = build_event("match-conn", "MESSAGE_CREATE")
    :ok = PubSub.broadcast("match-conn", event)

    assert_receive {:gateway_event, ^event}, 100

    :ok = PubSub.unsubscribe("match-conn", "MESSAGE_CREATE")
  end

  test "subscribe/1 receives any event type" do
    :ok = PubSub.subscribe("all-conn")
    e1 = build_event("all-conn", "READY", %{seq: 1})
    e2 = build_event("all-conn", "MESSAGE_CREATE", %{seq: 2})

    :ok = PubSub.broadcast("all-conn", e1)
    :ok = PubSub.broadcast("all-conn", e2)

    assert_receive {:gateway_event, ^e1}, 100
    assert_receive {:gateway_event, ^e2}, 100

    :ok = PubSub.unsubscribe("all-conn")
  end

  test "two subscribers on the same topic both receive one copy" do
    parent = self()

    task1 =
      Task.async(fn ->
        :ok = PubSub.subscribe("fanout")
        send(parent, :ready1)

        receive do
          {:gateway_event, e} -> e
        after
          200 -> :timeout
        end
      end)

    task2 =
      Task.async(fn ->
        :ok = PubSub.subscribe("fanout")
        send(parent, :ready2)

        receive do
          {:gateway_event, e} -> e
        after
          200 -> :timeout
        end
      end)

    assert_receive :ready1, 200
    assert_receive :ready2, 200

    event = build_event("fanout", "READY")
    :ok = PubSub.broadcast("fanout", event)

    assert Task.await(task1) == event
    assert Task.await(task2) == event
  end

  test "an :all subscriber receives one copy and a typed subscriber receives one copy" do
    parent = self()

    typed_task =
      Task.async(fn ->
        :ok = PubSub.subscribe("dual", "MESSAGE_CREATE")
        send(parent, :typed_ready)

        # Drain to count copies
        count =
          Stream.repeatedly(fn ->
            receive do
              {:gateway_event, _} -> 1
            after
              100 -> :done
            end
          end)
          |> Enum.take_while(&(&1 == 1))
          |> Enum.count()

        count
      end)

    assert_receive :typed_ready, 200

    :ok = PubSub.subscribe("dual")

    event = build_event("dual", "MESSAGE_CREATE")
    :ok = PubSub.broadcast("dual", event)

    # The calling process (an :all subscriber) gets exactly one message
    assert_receive {:gateway_event, ^event}, 100
    refute_receive {:gateway_event, _}, 50

    assert Task.await(typed_task) == 1

    :ok = PubSub.unsubscribe("dual")
  end

  test "separate connections do not cross-talk" do
    :ok = PubSub.subscribe("alpha")
    :ok = PubSub.broadcast("beta", build_event("beta", "READY"))

    refute_receive {:gateway_event, _}, 50

    :ok = PubSub.unsubscribe("alpha")
  end

  test "subscriber exit auto-deregisters and broadcast still succeeds" do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        :ok = PubSub.subscribe("ephemeral")
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed, 200
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 200

    # After exit, broadcasting must not crash, even though the original
    # subscriber pid is gone.
    assert :ok = PubSub.broadcast("ephemeral", build_event("ephemeral", "READY"))

    # And the calling pid can subscribe to the same topic without issue.
    :ok = PubSub.subscribe("ephemeral")
    :ok = PubSub.unsubscribe("ephemeral")
  end
end
