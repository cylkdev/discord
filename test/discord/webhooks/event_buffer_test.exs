defmodule Discord.Webhooks.EventBufferTest do
  use ExUnit.Case, async: false

  alias Discord.Webhooks.EventBuffer

  setup do
    EventBuffer.clear()
    :ok
  end

  test "push prepends and list returns newest first" do
    EventBuffer.push(%{type: "APPLICATION_AUTHORIZED"})
    EventBuffer.push(%{type: "ENTITLEMENT_CREATE"})

    assert [%{type: "ENTITLEMENT_CREATE"}, %{type: "APPLICATION_AUTHORIZED"}] = EventBuffer.list()
  end

  test "buffer is bounded by max" do
    for i <- 1..105, do: EventBuffer.push(%{type: "E", n: i})

    events = EventBuffer.list()
    assert length(events) == 100
    assert hd(events).n == 105
    assert List.last(events).n == 6
  end

  test "clear empties the buffer" do
    EventBuffer.push(%{type: "X"})
    assert EventBuffer.list() != []
    EventBuffer.clear()
    assert EventBuffer.list() == []
  end
end
