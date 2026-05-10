defmodule Mix.Tasks.Discord.Webhook.Start do
  @shortdoc "Starts the Discord webhook receiver"

  @moduledoc """
  Boots the Discord webhook receiver and keeps the BEAM alive until
  shutdown:

    * `Discord.Webhooks` — supervises the in-memory event buffer that
      `Discord.Endpoint.WebhooksPlug` writes to (started via the `:discord`
      application by `Mix.Discord.Utils.start!/0`).
    * `Discord.Endpoint` — the Bandit listener, also started by the
      `:discord` application. This task writes the listener's `--port`
      and `--public-key` into application env under
      `{:discord, Discord.Endpoint}` **before** starting `:discord` so
      the supervised endpoint comes up correctly configured.

  Configuration is sourced exclusively from CLI options. The application
  env is touched only as a transport between this task and
  `Discord.Endpoint.init/1`.

  Pair this with `mix discord.webhook.tunnel` in a second terminal to expose
  the local endpoint via Cloudflare.

      # terminal 1
      mix discord.webhook.start --public-key <hex>

      # terminal 2
      mix discord.webhook.tunnel

  Works the same under `iex -S mix discord.webhook.start --public-key <hex>`
  for an interactive shell with the receiver running.

  ## Usage

      mix discord.webhook.start --public-key <hex> [--port <int>] [--no-block]

  Options:

    * `--public-key` — hex-encoded Ed25519 public key for the Discord
      application. Required: without it `POST /webhooks` returns
      `503 webhooks_not_configured` and the task has nothing to do.
    * `--port` — Bandit listen port (default `4000`).
    * `--no-block` — boot the receiver and return immediately, without
      entering `mix run --no-halt`. Standalone callers should not pass
      this.

  ## Examples

  Start the receiver:

      mix discord.webhook.start --public-key MTAxMjM0NTY3ODkw...

  Boot on a non-default port:

      mix discord.webhook.start --public-key MTAxMjM0NTY3ODkw... --port 4001

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

  @logger_prefix "Mix.Tasks.Discord.Webhook.Start"

  @switches [public_key: :string, no_block: :boolean, port: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {public_key, opts} = Keyword.pop(opts, :public_key)
    {port, _opts} = Keyword.pop(opts, :port)

    public_key = require_public_key!(public_key)

    endpoint_env =
      [public_key: public_key]
      |> maybe_put(:port, port)

    apply_endpoint_env(endpoint_env)

    Mix.Discord.Utils.start!()

    Discord.Log.info(@logger_prefix, "webhook receiver running")
    Mix.shell().info("Discord webhook receiver running.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  defp apply_endpoint_env(new_opts) do
    current = Application.get_env(:discord, Discord.Endpoint, [])
    Application.put_env(:discord, Discord.Endpoint, Keyword.merge(current, new_opts))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp require_public_key!(value) when is_binary(value) and value != "", do: value

  defp require_public_key!(_) do
    Mix.raise("--public-key is required (hex-encoded Ed25519 key for the Discord application)")
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
