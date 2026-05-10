defmodule Mix.Tasks.Discord.Gateway.Start do
  @shortdoc "Starts the Discord Gateway WebSocket supervisor"

  @moduledoc """
  Boots the Discord Gateway WebSocket infrastructure and keeps the BEAM
  alive until shutdown:

    * `Discord.Gateways` — supervises the event buffer and the dynamic
      supervisor that hosts the Discord WebSocket (started via the
      `:discord` application by `Mix.Discord.Utils.start!/0`).
    * `Discord.Webhooks` — supervises the in-memory webhook event buffer
      that `Discord.Endpoint.WebhooksPlug` writes to (also started by
      `:discord`).
    * `Discord.Endpoint` — the Bandit listener, also started by the
      `:discord` application. This task writes the listener's `--port`
      into application env under `{:discord, Discord.Endpoint}` **before**
      starting `:discord` so the supervised endpoint comes up on the
      requested port.

  Webhook signature verification is not enabled by this task — operators
  who need it should run `mix discord.webhook.start` instead.
  Configuration is sourced exclusively from CLI options.

  Pair this with `mix discord.gateway.tunnel` in a second terminal to
  expose the local endpoint via Cloudflare.

      # terminal 1
      mix discord.gateway.start

      # terminal 2
      mix discord.gateway.tunnel

  Works the same under `iex -S mix discord.gateway.start` for an
  interactive shell with the gateway running.

  ## Usage

      mix discord.gateway.start [--token <bot-token>] [--name <name>] [--port <int>] [--no-block]

  Options:

    * `--token` — when given, opens the Discord Gateway WebSocket via
      `Discord.Gateways.connect/2` so events accumulate in the buffer.
      Pass the raw bot token, not `Bot <token>`.
    * `--name` — registry name for the spawned WebSocket (atom, default `:default`).
      Multiple invocations with distinct names can run concurrently.
    * `--port` — Bandit listen port (default `4000`).
    * `--no-block` — boot the gateway and return immediately, without
      entering `mix run --no-halt`. Standalone callers should not pass
      this.

  ## Examples

  Start the gateway:

      mix discord.gateway.start

  Start and immediately open the Discord WebSocket so
  `/gateways/default/events` populates:

      mix discord.gateway.start --token MTAxMjM0NTY3ODkw...

  Boot inside an IEx session (gives you a REPL alongside the running gateway):

      iex -S mix discord.gateway.start

  Smoke-test the local endpoint while running:

      curl http://localhost:4000/health
      curl http://localhost:4000/gateways/default/events

  ## Shutdown

  Ctrl-C triggers normal BEAM shutdown, which terminates the supervisors —
  Bandit drains, and `Discord.Gateways.WebSocket`'s `terminate/2` closes the
  WebSocket cleanly. Under `iex`, press Ctrl-C twice (or pick `a` from the
  BREAK menu).
  """

  use Mix.Task

  @logger_prefix "Mix.Tasks.Discord.Gateway.Start"

  @switches [
    token: :string,
    no_block: :boolean,
    name: :string,
    port: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {token, opts} = Keyword.pop(opts, :token)
    {name_opt, opts} = Keyword.pop(opts, :name)
    {port, _opts} = Keyword.pop(opts, :port)

    gateway_name =
      if is_binary(name_opt) and name_opt != "", do: String.to_atom(name_opt), else: :default

    endpoint_env = maybe_put([], :port, port)
    apply_endpoint_env(endpoint_env)

    Mix.Discord.Utils.start!()

    if is_binary(token) and token != "" do
      Discord.Log.info(@logger_prefix, "connecting gateway name=#{inspect(gateway_name)}")

      case Discord.Gateways.connect(gateway_name, token) do
        {:ok, _pid} ->
          Discord.Log.info(
            @logger_prefix,
            "gateway connection requested name=#{inspect(gateway_name)}"
          )

          Mix.shell().info(
            "Discord Gateway worker started (#{inspect(gateway_name)}). Waiting for Discord READY."
          )

        {:error, reason} ->
          Discord.Log.error(
            @logger_prefix,
            "gateway connect failed name=#{inspect(gateway_name)} reason=#{inspect(reason)}"
          )

          Mix.raise("Failed to connect Discord Gateway: #{inspect(reason)}")
      end
    end

    Discord.Log.info(@logger_prefix, "Discord Gateways running")
    Mix.shell().info("Discord Gateways running.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  defp apply_endpoint_env([]), do: :ok

  defp apply_endpoint_env(new_opts) do
    current = Application.get_env(:discord, Discord.Endpoint, [])
    Application.put_env(:discord, Discord.Endpoint, Keyword.merge(current, new_opts))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
