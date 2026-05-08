defmodule Mix.Tasks.Discord.Endpoint.Start do
  @shortdoc "Starts the Discord HTTP endpoint (Bandit listener)"

  @moduledoc """
  Boots the `Discord.Endpoint` Bandit listener and keeps the BEAM alive
  until shutdown. The listener fronts both `/gateways` and `/webhooks`
  (see `Discord.Endpoint.RequestPlug`); the domain-side state for those
  routes is brought up by `mix discord.gateway.start` and
  `mix discord.webhook.start` respectively.

  This task owns `Discord.Endpoint.start_link/1`. The gateway and webhook
  tasks delegate to it via `Mix.Task.run/2`, which is memoised within a
  node — so however many subsystems you bring up in one terminal, the
  listener is started exactly once.

  ## Usage

      mix discord.endpoint.start [--public-key <hex>] [--no-block]

  Options:

    * `--public-key` — hex-encoded Ed25519 public key for the Discord
      application. When omitted, `POST /webhooks` returns
      `503 webhooks_not_configured`.
    * `--no-block` — boot the endpoint and return immediately, without
      entering `mix run --no-halt`. Used by other tasks that delegate
      here and want to block on their own work instead.

  ## Examples

  Start the endpoint with no webhook verification:

      mix discord.endpoint.start

  Start the endpoint with webhook signature verification enabled:

      mix discord.endpoint.start --public-key MTAxMjM0NTY3ODkw...

  ## Shutdown

  Ctrl-C triggers normal BEAM shutdown; Bandit drains cleanly. Under
  `iex`, press Ctrl-C twice (or pick `a` from the BREAK menu).
  """

  use Mix.Task

  @switches [public_key: :string, no_block: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    {no_block, opts} = Keyword.pop(opts, :no_block, false)
    {public_key, _opts} = Keyword.pop(opts, :public_key)

    if is_binary(public_key) and public_key != "" do
      Application.put_env(:discord, :webhook_public_key, public_key)
    end

    Mix.Task.run("app.start", [])

    Mix.shell().info("Discord HTTP endpoint started.")

    unless no_block or iex_running?() do
      Mix.Tasks.Run.run(["--no-halt"])
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
