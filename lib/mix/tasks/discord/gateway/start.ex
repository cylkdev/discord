defmodule Mix.Tasks.Discord.Gateway.Start do
  @shortdoc "Starts the Discord Gateway WebSocket supervisor"

  @moduledoc """
  Boots the Discord Gateway WebSocket infrastructure and keeps the BEAM
  alive until shutdown:

    * `Discord.Gateways` — supervises the event buffer and the dynamic
      supervisor that hosts the Discord WebSocket.
    * `Discord.Webhooks` — supervises the in-memory webhook event buffer
      that `Discord.Endpoint.WebhooksPlug` writes to.

  The HTTP listener is owned by `mix discord.endpoint.start`; this task
  delegates to it (with `--no-block`) before starting its own supervisors.
  Webhook signature verification is not enabled by this task — operators
  who need it should run `mix discord.webhook.start` instead.

  Pair this with `mix discord.tunnel.start` in a second terminal to
  expose the local endpoint via Cloudflare.

      # terminal 1
      mix discord.gateway.start

      # terminal 2
      mix discord.tunnel.start

  Works the same under `iex -S mix discord.gateway.start` for an
  interactive shell with the gateway running.

  ## Usage

      mix discord.gateway.start [--token <bot-token>] [--name <name>] [--no-block]

  Options:

    * `--token` — when given, opens the Discord Gateway WebSocket via
      `Discord.Gateways.connect/2` so events accumulate in the buffer.
    * `--name` — registry name for the spawned WebSocket (atom, default `:default`).
      Multiple invocations with distinct names can run concurrently.
    * `--no-block` — boot the gateway and return immediately, without
      entering `mix run --no-halt`. Standalone callers should not pass
      this.

  ## Examples

  Start the gateway:

      mix discord.gateway.start

  Start and immediately open the Discord WebSocket so `/events` populates:

      mix discord.gateway.start --token MTAxMjM0NTY3ODkw...

  Boot inside an IEx session (gives you a REPL alongside the running gateway):

      iex -S mix discord.gateway.start

  Smoke-test the local endpoint while running:

      curl http://localhost:4000/health
      curl http://localhost:4000/events

  ## Shutdown

  Ctrl-C triggers normal BEAM shutdown, which terminates the supervisors —
  Bandit drains, and `Discord.Gateways.WebSocket`'s `terminate/2` closes the
  WebSocket cleanly. Under `iex`, press Ctrl-C twice (or pick `a` from the
  BREAK menu).
  """

  use Mix.Task

  @requirements ["app.start"]

  @switches [token: :string, no_block: :boolean, name: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {token, opts} = Keyword.pop(opts, :token)
    {name_opt, _opts} = Keyword.pop(opts, :name)

    gateway_name =
      if is_binary(name_opt) and name_opt != "", do: String.to_atom(name_opt), else: :default

    if is_binary(token) and token != "" do
      case Discord.Gateways.connect(gateway_name, token) do
        {:ok, _pid} ->
          Mix.shell().info("Discord Gateway WebSocket connected (#{inspect(gateway_name)}).")

        {:error, reason} ->
          Mix.raise("Failed to connect Discord Gateway: #{inspect(reason)}")
      end
    end

    Mix.shell().info("Discord Gateways running.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
