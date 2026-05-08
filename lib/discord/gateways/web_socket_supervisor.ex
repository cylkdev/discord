defmodule Discord.Gateways.WebSocketSupervisor do
  use DynamicSupervisor

  @name __MODULE__

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, Keyword.put(opts, :name, @name))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: opts[:shutdown] || 5_000
    }
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts the Gateway WebSocket connection under the dynamic supervisor using
  the supplied bot token.

  Returns `{:ok, pid}` on success, or `{:error, {:already_started, pid}}` if
  a connection is already running. Call `disconnect/0` first to swap tokens.
  """
  def connect(name, token, opts \\ []) when is_binary(token) and token != "" do
    DynamicSupervisor.start_child(
      @name,
      {Discord.Gateways.WebSocket, {name, token, opts}}
    )
  end

  @doc """
  Stops the Gateway connection. The HTTP API and event buffer keep running.
  """
  def disconnect(socket_pid) when is_pid(socket_pid) do
    DynamicSupervisor.terminate_child(@name, socket_pid)
  end

  def disconnect(key) do
    case Discord.Gateways.WebSocketRegistry.lookup(key) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@name, pid)
    end
  end
end
