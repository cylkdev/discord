defmodule Discord.Gateways.WebSocketSupervisor do
  use DynamicSupervisor

  @name __MODULE__
  @logger_prefix "Discord.Gateways.WebSocketSupervisor"

  def start_link(opts \\ []) do
    Discord.Log.info(@logger_prefix, "starting")
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
    Discord.Log.debug(@logger_prefix, "starting child name=#{inspect(name)}")

    case DynamicSupervisor.start_child(
           @name,
           {Discord.Gateways.WebSocket, {name, token, opts}}
         ) do
      {:ok, pid} = ok ->
        Discord.Log.info(
          @logger_prefix,
          "child started name=#{inspect(name)} pid=#{inspect(pid)}"
        )

        ok

      {:error, reason} = err ->
        Discord.Log.error(
          @logger_prefix,
          "child start failed name=#{inspect(name)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  @doc """
  Stops the Gateway connection. The HTTP API and event buffer keep running.
  """
  def disconnect(socket_pid) when is_pid(socket_pid) do
    Discord.Log.debug(@logger_prefix, "terminating child by pid pid=#{inspect(socket_pid)}")
    DynamicSupervisor.terminate_child(@name, socket_pid)
  end

  def disconnect(key) do
    Discord.Log.debug(@logger_prefix, "terminating child by name name=#{inspect(key)}")

    case Discord.Gateways.WebSocketRegistry.lookup(key) do
      nil ->
        Discord.Log.warning(@logger_prefix, "disconnect — registry miss name=#{inspect(key)}")
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(@name, pid)
    end
  end
end
