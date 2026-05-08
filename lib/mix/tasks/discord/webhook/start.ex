defmodule Mix.Tasks.Discord.Webhook.Start do
  @shortdoc "Starts the Discord webhook receiver"

  @moduledoc """
  Boots the Discord webhook receiver and keeps the BEAM alive until
  shutdown:

    * `Discord.Webhooks` — supervises the in-memory event buffer that
      `Discord.Endpoint.WebhooksPlug` writes to.

  The HTTP listener is owned by `mix discord.endpoint.start`; this task
  delegates to it (with `--public-key` and `--no-block`) before bringing
  up the buffer supervisor. That keeps the listener a singleton — running
  this task alongside `mix discord.gateway.start` in the same node still
  starts `Discord.Endpoint` exactly once.

  Pair this with `mix discord.tunnel.start` in a second terminal to expose
  the local endpoint via Cloudflare.

      # terminal 1
      mix discord.webhook.start --public-key <hex>

      # terminal 2
      mix discord.tunnel.start

  Works the same under `iex -S mix discord.webhook.start --public-key <hex>`
  for an interactive shell with the receiver running.

  ## Usage

      mix discord.webhook.start --public-key <hex> [--no-block]

  Options:

    * `--public-key` — hex-encoded Ed25519 public key for the Discord
      application. Required: without it `POST /webhooks` returns
      `503 webhooks_not_configured` and the task has nothing to do.
    * `--no-block` — boot the receiver and return immediately, without
      entering `mix run --no-halt`. Standalone callers should not pass
      this.

  ## Examples

  Start the receiver:

      mix discord.webhook.start --public-key MTAxMjM0NTY3ODkw...

  Boot inside an IEx session (gives you a REPL alongside the receiver):

      iex -S mix discord.webhook.start --public-key MTAxMjM0NTY3ODkw...

  Smoke-test the local endpoint while running:

      curl -i http://localhost:4000/webhooks
      # -> 405 method_not_allowed
      curl -i -X POST http://localhost:4000/webhooks
      # -> 401 invalid_signature

  ## Shutdown

  Ctrl-C triggers normal BEAM shutdown, which terminates the supervisor —
  Bandit drains cleanly. Under `iex`, press Ctrl-C twice (or pick `a` from
  the BREAK menu).
  """

  use Mix.Task

  @switches [public_key: :string, no_block: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {public_key, _opts} = Keyword.pop(opts, :public_key)

    public_key = require_public_key!(public_key)
    Application.put_env(:discord, :webhook_public_key, public_key)

    Mix.Task.run("app.start", [])

    Mix.shell().info("Discord webhook receiver running.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  defp require_public_key!(value) when is_binary(value) and value != "", do: value

  defp require_public_key!(_) do
    Mix.raise("--public-key is required (hex-encoded Ed25519 key for the Discord application)")
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
