defmodule Discord.GatewaysTest do
  use ExUnit.Case, async: false

  alias Discord.Gateways.PubSub

  setup_all do
    start_supervised!({Discord.Gateways, []})
    :ok
  end

  test "connect/2 rejects non-binary or empty tokens" do
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, nil) end
    assert_raise FunctionClauseError, fn -> Discord.Gateways.connect(:test, "") end
  end

  test "subscribe/1 then a PubSub broadcast delivers a gateway_event message" do
    :ok = Discord.Gateways.subscribe(:main)

    event = %{
      connection: "main",
      type: "MESSAGE_CREATE",
      seq: 1,
      received_at: "2026-05-14T00:00:00Z",
      data: %{}
    }

    :ok = PubSub.broadcast(:main, event)

    assert_receive {:gateway_event, ^event}, 100

    :ok = Discord.Gateways.unsubscribe(:main)
  end

  test "subscribe/2 filters by event type" do
    :ok = Discord.Gateways.subscribe(:typed, "MESSAGE_CREATE")

    other_event = %{
      connection: "typed",
      type: "READY",
      seq: 1,
      received_at: "2026-05-14T00:00:00Z",
      data: %{}
    }

    :ok = PubSub.broadcast(:typed, other_event)
    refute_receive {:gateway_event, _}, 50

    matching_event = %{other_event | type: "MESSAGE_CREATE", seq: 2}
    :ok = PubSub.broadcast(:typed, matching_event)
    assert_receive {:gateway_event, ^matching_event}, 100

    :ok = Discord.Gateways.unsubscribe(:typed, "MESSAGE_CREATE")
  end
end
