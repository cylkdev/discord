defmodule Discord.Endpoint do
  @moduledoc false

  use Supervisor

  @default_port 4000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {port, plug_opts} = Keyword.pop(opts, :port)

    children = [
      {Bandit, plug: {Discord.Endpoint.RequestPlug, plug_opts}, port: port || @default_port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
