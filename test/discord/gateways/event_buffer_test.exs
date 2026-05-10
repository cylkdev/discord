defmodule Discord.Gateways.EventBufferTest do
  use ExUnit.Case, async: false

  alias Discord.Gateways.EventBuffer

  setup_all do
    start_supervised!({EventBuffer, []})
    :ok
  end

  setup do
    EventBuffer.clear()
    :ok
  end

  test "push prepends and list returns newest first for one connection" do
    EventBuffer.push("main", %{type: "A"})
    EventBuffer.push("main", %{type: "B"})

    assert [%{type: "B"}, %{type: "A"}] = EventBuffer.list("main")
  end

  test "buffer is bounded by max per connection" do
    # Default max is 100; push 105 and verify only last 100 remain.
    for i <- 1..105, do: EventBuffer.push("main", %{type: "E", n: i})

    events = EventBuffer.list("main")
    assert length(events) == 100
    assert hd(events).n == 105
    assert List.last(events).n == 6
  end

  test "clear empties one named buffer" do
    EventBuffer.push("main", %{type: "X"})
    assert EventBuffer.list("main") != []
    EventBuffer.clear("main")
    assert EventBuffer.list("main") == []
  end

  test "buffers are isolated by connection" do
    EventBuffer.push("main", %{type: "A"})
    EventBuffer.push("secondary", %{type: "B"})

    assert [%{type: "A"}] = EventBuffer.list("main")
    assert [%{type: "B"}] = EventBuffer.list("secondary")
  end
end
