defmodule Discord.Gateways.WebSocketRegistry do
  @moduledoc """
  Registry for tracking Discord Gateway WebSocket connections.
  """

  @name Discord.Gateways.WebSocketRegistry
  @unique :unique

  def start_link(opts) do
    opts
    |> Keyword.put(:keys, @unique)
    |> Keyword.put(:name, @name)
    |> Registry.start_link()
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def lookup(name) do
    case Registry.lookup(@name, name) do
      [] -> nil
      [{pid, _}] -> pid
    end
  end

  def keys(pid), do: Registry.keys(@name, pid)
end
