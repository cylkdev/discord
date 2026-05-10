defmodule Mix.Tasks.Discord.Webhook.Tunnel do
  @shortdoc "Starts the Cloudflare tunnel that fronts the Discord webhook receiver"

  @moduledoc """
  Provisions a remote-managed Cloudflare tunnel via `Flared.MixTask.run_remote/3`
  and runs `cloudflared` in the foreground, routing the webhook public
  hostname to the locally-running Bandit listener (started by
  `mix discord.webhook.start`). Cloudflare-side state is deprovisioned
  when `cloudflared` exits.

  This task does NOT start the `:discord` application — only `:flared`
  and its own dependencies (e.g. `:erlexec`). That keeps it free of the
  local Bandit listener and lets it run in a second terminal alongside
  `mix discord.webhook.start` without colliding on port 4000.

  Pair this with `mix discord.webhook.start --public-key <hex>` in
  another terminal:

      # terminal 1
      mix discord.webhook.start --public-key <hex>

      # terminal 2
      mix discord.webhook.tunnel

  ## Usage

      mix discord.webhook.tunnel \\
        [--name <tunnel-name>] \\
        [--hostname <public-host>] \\
        [--scheme http|https] \\
        [--service-domain <host>] \\
        [--service-port <port>]

  Defaults:

    * `--name` — `"discord-webhook"`
    * `--hostname` — `"discord-webhook-cloudflared.cylk.dev"`
    * `--scheme` — `:http`
    * `--service-domain` — `"localhost"`
    * `--service-port` — `4000` (matches the default Bandit listener port)

  ## Examples

  Open the default webhook tunnel (`discord-webhook` →
  `discord-webhook-cloudflared.cylk.dev` → `http://localhost:4000`):

      mix discord.webhook.tunnel

  Use a different public hostname and tunnel name (e.g. for a personal
  dev environment):

      mix discord.webhook.tunnel \\
        --name kurt-discord-webhook \\
        --hostname kurt-discord-webhook-cloudflared.cylk.dev

  Point at a non-default backend port (e.g. when the server runs on `:4001`):

      mix discord.webhook.tunnel --service-port 4001

  Smoke-test the public URL after cloudflared connects (a missing-header
  POST returning `401 invalid_signature` confirms the path from Discord
  is open and signature verification is engaged):

      curl -i https://discord-webhook-cloudflared.cylk.dev/health
      # -> 200 OK
      curl -i -X POST https://discord-webhook-cloudflared.cylk.dev/webhooks
      # -> 401 invalid_signature
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    Mix.Discord.Tunnel.run(args,
      name: "discord-webhook",
      hostname: "discord-webhook-cloudflared.cylk.dev"
    )
  end
end
