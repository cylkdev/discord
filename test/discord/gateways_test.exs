defmodule Discord.GatewaysTest do
  use ExUnit.Case, async: false

  alias Discord.Gateways.EventBuffer

  setup_all do
    start_supervised!({Discord.Gateways, []})
    :ok
  end

  setup do
    EventBuffer.clear()
    :ok
  end

  test "connect/2 rejects non-binary or empty tokens" do
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, nil) end
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, "") end
  end

  test "supported_event_types/0 returns the exact literal list" do
    assert Discord.Gateways.supported_event_types() == [
             "READY",
             "RESUMED",
             "MESSAGE_CREATE",
             "MESSAGE_UPDATE",
             "MESSAGE_DELETE",
             "MESSAGE_DELETE_BULK"
           ]
  end

  test "events/1 returns all events for one connection" do
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 1, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 2, data: %{}})

    EventBuffer.push("secondary", %{
      connection: :secondary,
      type: "MESSAGE_DELETE",
      seq: 3,
      data: %{}
    })

    assert [
             %{type: "MESSAGE_CREATE", connection: :main},
             %{type: "READY", connection: :main}
           ] = Discord.Gateways.events(:main)
  end

  test "events/2 with limit returns newest events for one connection" do
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 1, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 2, data: %{}})

    assert [%{type: "MESSAGE_CREATE"}] = Discord.Gateways.events(:main, limit: 1)
  end

  test "events/3 filters by supported event type" do
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 1, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 2, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 3, data: %{}})

    assert [%{seq: 3}, %{seq: 2}] = Discord.Gateways.events(:main, "MESSAGE_CREATE", [])
  end

  test "events/3 raises on unsupported event types" do
    assert_raise ArgumentError,
                 ~r/unsupported gateway event type "THREAD_CREATE"/,
                 fn ->
                   Discord.Gateways.events(:main, "THREAD_CREATE", [])
                 end
  end

  test "clear_events/1 removes only one connection buffer" do
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 1, data: %{}})
    EventBuffer.push("secondary", %{connection: :secondary, type: "READY", seq: 2, data: %{}})

    assert :ok = Discord.Gateways.clear_events(:main)
    assert Discord.Gateways.events(:main) == []
    assert [%{connection: :secondary}] = Discord.Gateways.events(:secondary)
  end
end
