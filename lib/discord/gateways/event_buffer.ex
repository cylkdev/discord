defmodule Discord.Gateways.EventBuffer do
  @moduledoc """
  Bounded in-memory buffer of recent Discord Gateway Dispatch events.

  Events are stored newest-first. The buffer is capped at `:max` (default 100);
  pushing past the cap drops the oldest event.
  """

  use GenServer

  @default_max 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def push(event), do: GenServer.cast(__MODULE__, {:push, event})

  def list, do: GenServer.call(__MODULE__, :list)

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(opts) do
    {:ok, %{events: [], max: Keyword.get(opts, :max, @default_max)}}
  end

  @impl true
  def handle_cast({:push, event}, %{events: events, max: max} = state) do
    {:noreply, %{state | events: Enum.take([event | events], max)}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.events, state}
  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | events: []}}
end
