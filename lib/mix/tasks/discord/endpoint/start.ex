defmodule Mix.Tasks.Discord.Endpoint.Start do
  @shortdoc "Starts the Discord HTTP endpoint (Bandit listener)"

  @moduledoc """
  Boots the `Discord.Endpoint` Bandit listener and keeps the BEAM alive
  until shutdown. The listener fronts both `/gateways` and `/webhooks`
  (see `Discord.Endpoint.RequestPlug`); the domain-side state for those
  routes is brought up by `mix discord.gateway.start` and
  `mix discord.webhook.start` respectively.

  CLI options are translated into application environment under
  `{:discord, Discord.Endpoint}` **before** the `:discord` application
  starts. The OTP supervisor (`Discord.Application`) then brings the
  listener up itself, so Bandit's lifetime is the BEAM's lifetime —
  not the Mix task process's lifetime.

  Configuration is sourced exclusively from CLI options. The application
  env is touched only as a transport between this task and
  `Discord.Endpoint.init/1`. Omit any option to fall back to the
  module-level default (port `4000`; webhook verification disabled).

  ## Usage

      mix discord.endpoint.start [--port <int>] [--public-key <hex>] [--no-block]

  Options:

    * `--port` — Bandit listen port. Defaults to `4000` when omitted.
    * `--public-key` — hex-encoded Ed25519 public key for the Discord
      application. When omitted, `POST /webhooks` returns
      `503 webhooks_not_configured`.
    * `--no-block` — boot the endpoint and return immediately, without
      entering `mix run --no-halt`. Used by other tasks that delegate
      here and want to block on their own work instead.

  ## Examples

  Start the endpoint with no webhook verification:

      mix discord.endpoint.start

  Start on a non-default port:

      mix discord.endpoint.start --port 4001

  Start the endpoint with webhook signature verification enabled:

      mix discord.endpoint.start --public-key MTAxMjM0NTY3ODkw...

  ## Shutdown

  Ctrl-C triggers normal BEAM shutdown; Bandit drains cleanly. Under
  `iex`, press Ctrl-C twice (or pick `a` from the BREAK menu).
  """

  use Mix.Task

  @logger_prefix "Mix.Tasks.Discord.Endpoint.Start"

  @default_port 4000

  @switches [port: :integer, public_key: :string, no_block: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {port, opts} = Keyword.pop(opts, :port)
    {public_key, _opts} = Keyword.pop(opts, :public_key)

    endpoint_env =
      []
      |> maybe_put(:port, port)
      |> maybe_put(:public_key, sanitize_public_key(public_key))

    apply_endpoint_env(endpoint_env)

    Mix.Discord.Utils.start!()

    Discord.Log.info(@logger_prefix, "endpoint started",
      port: port || @default_port,
      webhooks_configured?: Keyword.has_key?(endpoint_env, :public_key)
    )

    Mix.shell().info("Discord HTTP endpoint started.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  # Merge CLI-supplied options into the existing app env so that callers
  # which set their own keys (e.g. webhook.start setting :public_key
  # before delegating, or vice versa) compose cleanly. Existing keys are
  # preserved when this task does not override them.
  defp apply_endpoint_env([]), do: :ok

  defp apply_endpoint_env(new_opts) do
    current = Application.get_env(:discord, Discord.Endpoint, [])
    Application.put_env(:discord, Discord.Endpoint, Keyword.merge(current, new_opts))
  end

  defp sanitize_public_key(value) when is_binary(value) and value != "", do: value
  defp sanitize_public_key(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
