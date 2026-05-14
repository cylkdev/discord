defmodule Discord.Webhooks.PubSubTest do
  use ExUnit.Case, async: false

  alias Discord.Webhooks.PubSub

  setup_all do
    start_supervised!({PubSub, []})
    :ok
  end

  defp build_event(type, extra \\ %{}) do
    Map.merge(
      %{
        type: type,
        received_at: "2026-05-14T00:00:00Z",
        payload: %{}
      },
      extra
    )
  end

  test "subscribe/0 then broadcast delivers a :webhook_event message" do
    :ok = PubSub.subscribe()
    event = build_event("APPLICATION_AUTHORIZED")
    :ok = PubSub.broadcast(event)

    assert_receive {:webhook_event, ^event}, 100

    :ok = PubSub.unsubscribe()
  end

  test "broadcast with no subscribers does not crash" do
    # Ensure caller is not subscribed first.
    :ok = PubSub.unsubscribe()
    assert :ok = PubSub.broadcast(build_event("ENTITLEMENT_CREATE"))
    refute_receive {:webhook_event, _}, 50
  end

  test "two subscribers both receive a single broadcast" do
    parent = self()

    t1 =
      Task.async(fn ->
        :ok = PubSub.subscribe()
        send(parent, :r1)

        receive do
          {:webhook_event, e} -> e
        after
          200 -> :timeout
        end
      end)

    t2 =
      Task.async(fn ->
        :ok = PubSub.subscribe()
        send(parent, :r2)

        receive do
          {:webhook_event, e} -> e
        after
          200 -> :timeout
        end
      end)

    assert_receive :r1, 200
    assert_receive :r2, 200

    event = build_event("ENTITLEMENT_CREATE")
    :ok = PubSub.broadcast(event)

    assert Task.await(t1) == event
    assert Task.await(t2) == event
  end

  test "subscriber exit auto-deregisters; broadcast still succeeds" do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        :ok = PubSub.subscribe()
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed, 200
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 200

    assert :ok = PubSub.broadcast(build_event("APPLICATION_AUTHORIZED"))

    :ok = PubSub.subscribe()
    :ok = PubSub.unsubscribe()
  end
end
