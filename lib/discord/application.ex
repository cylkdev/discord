defmodule Discord.Application do
  @moduledoc """
  Owns the Discord supervision tree:

      Discord.Supervisor
        ├── Discord.Gateways          (WebSocket registry, dynamic supervisor, event buffer)
        ├── Discord.Webhooks          (webhook event buffer)
        └── Discord.Endpoint          (Bandit listener fronting /gateways and /webhooks)

  Owned by the OTP application master, so it's BEAM-lifetime. Mix tasks
  must NOT call `Discord.Gateways.start_link/1`, `Discord.Endpoint.start_link/1`,
  etc. directly — those supervisors come up here, once, when the `:discord`
  application starts.

  ## Endpoint configuration

  `Discord.Endpoint` reads its per-invocation configuration from the
  application environment under the key `{:discord, Discord.Endpoint}` at
  supervisor init time:

      config :discord, Discord.Endpoint, port: 4000, public_key: "..."

  Mix tasks (`mix discord.endpoint.start`, `mix discord.webhook.start`,
  `mix discord.gateway.start`) translate CLI flags (`--port`,
  `--public-key`) into `Application.put_env/3` calls **before** invoking
  `Mix.Discord.Utils.start!/0`, so the supervised endpoint comes up with
  the operator's chosen settings on the first (and only) start.

  This put-env-then-start pattern matters: starting the listener directly
  from a Mix task process links Bandit to that process, so when the task
  returns the socket dies even though the BEAM keeps running. Putting
  config first and letting the OTP supervisor own the listener keeps it
  alive for the BEAM lifetime.

  Compile-time gating: `Discord.Config.server_enabled?/0` (set in
  `config/config.exs`) suppresses every supervised child in test
  environments, so unit tests can exercise plugs directly without a live
  socket.
  """

  use Application

  @logger_prefix "Discord.Application"

  @impl true
  def start(_type, _args) do
    Discord.Log.info(@logger_prefix, "application starting")

    children = children()
    Supervisor.start_link(children, strategy: :one_for_one, name: Discord.Supervisor)
  end

  @doc """
  Returns the list of children supervised by `Discord.Supervisor`.

  Returns `[Discord.Gateways, Discord.Webhooks, Discord.Endpoint]` when
  the server is enabled, else `[]`. `Discord.Endpoint` reads its options
  from `Application.get_env(:discord, Discord.Endpoint, [])`.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    if Discord.Config.server_enabled?() do
      [
        Discord.Gateways,
        Discord.Webhooks,
        Discord.Endpoint
      ]
    else
      []
    end
  end
end
