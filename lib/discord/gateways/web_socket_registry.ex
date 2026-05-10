defmodule Discord.Gateways.WebSocketRegistry do
  @moduledoc """
  Registry for tracking Discord Gateway WebSocket connections.
  """

  @name Discord.Gateways.WebSocketRegistry
  @unique :unique
  @logger_prefix "Discord.Gateways.WebSocketRegistry"

  def start_link(opts) do
    Discord.Log.info(@logger_prefix, "registry starting")

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
      [] ->
        Discord.Log.debug(@logger_prefix, "lookup miss name=#{inspect(name)}")
        nil

      [{pid, _}] ->
        Discord.Log.debug(@logger_prefix, "lookup hit name=#{inspect(name)} pid=#{inspect(pid)}")
        pid
    end
  end

  def keys(pid), do: Registry.keys(@name, pid)
end
