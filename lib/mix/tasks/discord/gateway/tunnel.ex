defmodule Mix.Tasks.Discord.Gateway.Tunnel do
  @shortdoc "Starts the Cloudflare tunnel that fronts the Discord Gateway HTTP routes"

  @moduledoc """
  Provisions a remote-managed Cloudflare tunnel via `Flared.MixTask.run_remote/3`
  and runs `cloudflared` in the foreground, routing the gateway public
  hostname to the locally-running Bandit listener (started by
  `mix discord.gateway.start`). Cloudflare-side state is deprovisioned
  when `cloudflared` exits.

  This task does NOT start the `:discord` application — only `:flared`
  and its own dependencies (e.g. `:erlexec`). That keeps it free of the
  local Bandit listener and lets it run in a second terminal alongside
  `mix discord.gateway.start` without colliding on port 4000.

  Pair this with `mix discord.gateway.start` in another terminal:

      # terminal 1
      mix discord.gateway.start

      # terminal 2
      mix discord.gateway.tunnel

  ## Usage

      mix discord.gateway.tunnel \\
        [--name <tunnel-name>] \\
        [--hostname <public-host>] \\
        [--scheme http|https] \\
        [--service-domain <host>] \\
        [--service-port <port>]

  Defaults:

    * `--name` — `"discord-gateway"`
    * `--hostname` — `"discord-gateway-cloudflared.cylk.dev"`
    * `--scheme` — `:http`
    * `--service-domain` — `"localhost"`
    * `--service-port` — `4000` (matches the default Bandit listener port)

  ## Examples

  Open the default gateway tunnel (`discord-gateway` →
  `discord-gateway-cloudflared.cylk.dev` → `http://localhost:4000`):

      mix discord.gateway.tunnel

  Use a different public hostname and tunnel name (e.g. for a personal
  dev environment):

      mix discord.gateway.tunnel \\
        --name kurt-discord-gateway \\
        --hostname kurt-discord-gateway-cloudflared.cylk.dev

  Point at a non-default backend port (e.g. when the server runs on `:4001`):

      mix discord.gateway.tunnel --service-port 4001

  Smoke-test the public URL after cloudflared connects:

      curl https://discord-gateway-cloudflared.cylk.dev/health
      curl https://discord-gateway-cloudflared.cylk.dev/gateways/default/events
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    Mix.Discord.Tunnel.run(args,
      name: "discord-gateway",
      hostname: "discord-gateway-cloudflared.cylk.dev"
    )
  end
end
