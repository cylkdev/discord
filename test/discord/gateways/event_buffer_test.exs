defmodule Discord.Gateways.EventBufferTest do
  use ExUnit.Case, async: false

  alias Discord.Gateways.EventBuffer

  setup do
    EventBuffer.clear()
    :ok
  end

  test "push prepends and list returns newest first" do
    EventBuffer.push(%{type: "A"})
    EventBuffer.push(%{type: "B"})

    assert [%{type: "B"}, %{type: "A"}] = EventBuffer.list()
  end

  test "buffer is bounded by max" do
    # Default max is 100; push 105 and verify only last 100 remain.
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
