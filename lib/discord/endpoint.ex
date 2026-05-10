defmodule Discord.Endpoint do
  @moduledoc """
  Supervises the Bandit HTTP listener that fronts `/gateways` and
  `/webhooks` (see `Discord.Endpoint.RequestPlug`).

  Owned by `Discord.Application` for BEAM lifetime. Configuration is
  read at init time from the application environment:

      config :discord, Discord.Endpoint,
        port: 4000,
        public_key: "<hex-ed25519>"

  Mix tasks set this via `Application.put_env/3` before starting the
  `:discord` application. Explicit options passed to `start_link/1`
  override the application env (used by tests or callers that want a
  one-off configuration).
  """

  use Supervisor

  @logger_prefix "Discord.Endpoint"

  @default_port 4000

  @doc """
  Starts the endpoint supervisor.

  Options merge over the application env (`{:discord, Discord.Endpoint}`):
  explicit `opts` win on conflict. Recognised keys:

    * `:port` — Bandit listen port. Default `4000`.
    * `:public_key` — hex-encoded Ed25519 public key forwarded to the
      webhook plug. Omitted means webhook signature verification is
      not configured (POST /webhooks returns 503).

  Any other keys are passed through as plug options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    env_opts = Application.get_env(:discord, __MODULE__, [])
    merged = Keyword.merge(env_opts, opts)

    {port, plug_opts} = Keyword.pop(merged, :port)
    listen_port = port || @default_port

    Discord.Log.info(@logger_prefix, "starting Bandit", port: listen_port)

    children = [
      {Bandit, plug: {Discord.Endpoint.RequestPlug, plug_opts}, port: listen_port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
