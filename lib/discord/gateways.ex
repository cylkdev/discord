defmodule Discord.Gateways do
  @moduledoc """
  Minimal Discord Gateway client.

  Supervises the event buffer, the HTTP API, and the dynamic supervisor that
  hosts the Gateway WebSocket connection. Open a connection by passing the
  bot token explicitly:

      Discord.Gateways.connect(:main, "YOUR_BOT_TOKEN")

  Then poll received events:

      curl http://localhost:4000/events

  The token must be a string. There is no implicit token loading from
  application config or environment variables.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Discord.Gateways.WebSocketRegistry, opts},
      {Discord.Gateways.WebSocketSupervisor, opts},
      {Discord.Gateways.EventBuffer, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts a Gateway WebSocket connection under the dynamic supervisor, registered
  under `name`. `name` can be any term (atom, string, tuple); it is the registry
  key used by `Discord.Gateways.WebSocket.connected?/1` and `disconnect/1`.

  Returns `{:ok, pid}` on success, or `{:error, {:already_started, pid}}` if a
  connection with that name already exists.
  """
  def connect(name, token) when is_binary(token) and token != "" do
    Discord.Gateways.WebSocketSupervisor.connect(name, token)
  end

  @doc """
  Stops the named Gateway connection. The HTTP API and event buffer keep running.
  """
  def disconnect(name) do
    Discord.Gateways.WebSocketSupervisor.disconnect(name)
  end

  def list_connection_info do
    Enum.map(list_connections(), fn {name, _pid} ->
      %{
        name: to_string(name),
        connected: Discord.Gateways.WebSocket.connected?(name)
      }
    end)
  end

  @doc """
  Lists every running Gateway connection as `[{name, pid}, ...]`.

  Walks the dynamic supervisor (the source of truth for "alive") and resolves
  each child's registered name via `Registry.keys/2`. Children that haven't
  registered yet, or whose pids have just died, are skipped.
  """
  def list_connections do
    Discord.Gateways.WebSocketSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        Enum.map(Discord.Gateways.WebSocketRegistry.keys(pid), &{&1, pid})

      _ ->
        []
    end)
  end
end
