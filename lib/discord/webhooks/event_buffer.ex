defmodule Discord.Webhooks.EventBuffer do
  @moduledoc """
  Bounded in-memory buffer of recent Discord webhook events.

  Events are stored newest-first. The buffer is capped at `:max` (default 100);
  pushing past the cap drops the oldest event. Mirrors
  `Discord.Gateways.EventBuffer` but is intentionally a separate process so
  webhook deliveries and Gateway dispatches don't intermix.
  """

  use GenServer

  @logger_prefix "Discord.Webhooks.EventBuffer"

  @default_max 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def push(event), do: GenServer.cast(__MODULE__, {:push, event})

  def list, do: GenServer.call(__MODULE__, :list)

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max, @default_max)
    Discord.Log.info(@logger_prefix, "starting", max: max)
    {:ok, %{events: [], max: max}}
  end

  @impl true
  def handle_cast({:push, event}, %{events: events, max: max} = state) do
    new_events = Enum.take([event | events], max)
    new_size = length(new_events)

    if length(events) >= max do
      Discord.Log.warning(@logger_prefix, "buffer at capacity — dropped oldest event",
        max: max,
        type: event[:type]
      )
    end

    Discord.Log.debug(@logger_prefix, "event pushed",
      type: event[:type],
      size: new_size
    )

    {:noreply, %{state | events: new_events}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    Discord.Log.debug(@logger_prefix, "list requested", size: length(state.events))
    {:reply, state.events, state}
  end

  def handle_call(:clear, _from, state) do
    Discord.Log.debug(@logger_prefix, "buffer cleared", previous_size: length(state.events))
    {:reply, :ok, %{state | events: []}}
  end
end
