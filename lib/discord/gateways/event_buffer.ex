defmodule Discord.Gateways.EventBuffer do
  @moduledoc """
  Bounded in-memory buffer of recent Discord Gateway Dispatch events.

  Events are stored newest-first per connection. Each connection buffer is
  capped at `:max` (default 100); pushing past the cap drops the oldest event
  for that connection.
  """

  use GenServer

  @logger_prefix "Discord.Gateways.EventBuffer"

  @default_max 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def push(connection, event) when is_binary(connection) and is_map(event) do
    GenServer.cast(__MODULE__, {:push, connection, event})
  end

  def list(connection) when is_binary(connection),
    do: GenServer.call(__MODULE__, {:list, connection})

  def count(connection) when is_binary(connection),
    do: GenServer.call(__MODULE__, {:count, connection})

  def clear(connection) when is_binary(connection),
    do: GenServer.call(__MODULE__, {:clear, connection})

  def clear, do: GenServer.call(__MODULE__, :clear_all)

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max, @default_max)
    Discord.Log.info(@logger_prefix, "starting buffer max=#{max}")
    {:ok, %{by_connection: %{}, max: max}}
  end

  @impl true
  def handle_cast({:push, connection, event}, %{by_connection: by_connection, max: max} = state) do
    events = Map.get(by_connection, connection, [])
    new_events = Enum.take([event | events], max)
    new_size = length(new_events)

    if length(events) >= max do
      Discord.Log.warning(
        @logger_prefix,
        "buffer at capacity — dropped oldest event max=#{max} connection=#{inspect(connection)} type=#{inspect(event[:type])}"
      )
    end

    Discord.Log.debug(
      @logger_prefix,
      "buffered event connection=#{inspect(connection)} type=#{inspect(event[:type])} seq=#{inspect(event[:seq])} size=#{new_size}"
    )

    {:noreply, %{state | by_connection: Map.put(by_connection, connection, new_events)}}
  end

  @impl true
  def handle_call({:list, connection}, _from, %{by_connection: by_connection} = state) do
    events = Map.get(by_connection, connection, [])

    Discord.Log.debug(
      @logger_prefix,
      "list requested connection=#{inspect(connection)} size=#{length(events)}"
    )

    {:reply, events, state}
  end

  def handle_call({:count, connection}, _from, %{by_connection: by_connection} = state) do
    {:reply, by_connection |> Map.get(connection, []) |> length(), state}
  end

  def handle_call({:clear, connection}, _from, %{by_connection: by_connection} = state) do
    previous_size = by_connection |> Map.get(connection, []) |> length()

    Discord.Log.debug(
      @logger_prefix,
      "buffer cleared connection=#{inspect(connection)} previous_size=#{previous_size}"
    )

    {:reply, :ok, %{state | by_connection: Map.delete(by_connection, connection)}}
  end

  def handle_call(:clear_all, _from, state) do
    previous_size =
      state.by_connection
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    Discord.Log.debug(@logger_prefix, "all buffers cleared previous_size=#{previous_size}")
    {:reply, :ok, %{state | by_connection: %{}}}
  end
end
