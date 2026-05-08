defmodule Discord.Application do
  @moduledoc """
  Owns the Discord supervision tree:

      Discord.Supervisor
        ├── Discord.Gateways          (WebSocket registry, dynamic supervisor, event buffer)
        ├── Discord.Webhooks         (webhook event buffer)
        └── Discord.Endpoint         (Bandit + RequestPlug fronting /gateways and /webhooks)

  Owned by the OTP application master, so it's BEAM-lifetime. Mix tasks
  must NOT call `Discord.Gateways.start_link/1` etc. directly — those
  supervisors come up here, once, when the `:discord` application starts.

  Endpoint configuration:

    * `:discord, :endpoint_port`        — Bandit listen port (default 4000)
    * `:discord, :webhook_public_key`   — hex Ed25519 key for webhook signature
                                          verification. Without it, `POST /webhooks`
                                          returns 503.

  Mix tasks set these via `Application.put_env/3` before invoking
  `mix app.start`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Discord.Gateways,
      Discord.Webhooks,
      {Discord.Endpoint, endpoint_opts()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Discord.Supervisor)
  end

  defp endpoint_opts do
    []
    |> put_if(:port, Application.get_env(:discord, :endpoint_port))
    |> put_if(:public_key, Application.get_env(:discord, :webhook_public_key))
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
