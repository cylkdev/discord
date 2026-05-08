defmodule Mix.Tasks.Discord.Tunnel.Start do
  @shortdoc "Starts the Cloudflare tunnel that fronts the Discord Gateway HTTP endpoint"

  @moduledoc """
  Provisions a remote-managed Cloudflare tunnel via `Flared.MixTask.run_remote/3`
  and runs `cloudflared` in the foreground, routing the configured public hostname
  to the locally running Bandit listener supervised by `Discord.Gateways`.
  Cloudflare-side state is deprovisioned when `cloudflared` exits.

  ## Usage

      mix discord.tunnel.start \\
        [--name <tunnel-name>] \\
        [--hostname <public-host>] \\
        [--scheme http|https] \\
        [--service-domain <host>] \\
        [--service-port <port>]

  Defaults:

    * `--name` — `"discord-gateway"`
    * `--hostname` — `"discord-gateway.cloudflared.cylk.dev"`
    * `--scheme` — `:http`
    * `--service-domain` — `"localhost"`
    * `--service-port` — `4000` (matches `Discord.Gateways`'s Bandit listener)

  ## Examples

  Open the default tunnel (`discord-gateway` → `discord-gateway.cloudflared.cylk.dev` →
  `http://localhost:4000`). Run `mix discord.gateway.start` in another
  terminal first so port 4000 is bound:

      mix discord.tunnel.start

  Point at a non-default backend port (e.g. when the server runs on `:4001`):

      mix discord.tunnel.start --service-port 4001

  Use a different public hostname and tunnel name (e.g. for a personal dev
  environment):

      mix discord.tunnel.start \\
        --name kurt-discord-gateway \\
        --hostname kurt-discord-gateway.cloudflared.cylk.dev

  Front a backend that already terminates TLS on a non-default port:

      mix discord.tunnel.start \\
        --scheme https \\
        --service-domain api.local \\
        --service-port 8443

  Smoke-test the public URL after cloudflared connects:

      curl https://discord-gateway.cloudflared.cylk.dev/health
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [
    name: :string,
    hostname: :string,
    scheme: :string,
    service_domain: :string,
    service_port: :integer
  ]

  @default_name "discord-gateway"
  @default_hostname "discord-gateway.cloudflared.cylk.dev"
  @default_scheme :http
  @default_service_domain "localhost"
  @default_service_port 4000

  @impl Mix.Task
  def run(args) do
    Mix.Discord.Utils.start!()
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    opts = normalize(opts)

    name = opts[:name] || @default_name

    Flared.MixTask.run_remote(name, routes(opts), flared_opts(opts))
  end

  defp normalize(opts) do
    Enum.map(opts, fn
      {:scheme, raw} -> {:scheme, parse_scheme(raw)}
      other -> other
    end)
  end

  defp parse_scheme("http"), do: :http
  defp parse_scheme("https"), do: :https

  defp parse_scheme(other) do
    Mix.raise(~s(--scheme must be "http" or "https", got: #{inspect(other)}))
  end

  defp routes(opts) do
    [%{hostname: opts[:hostname] || @default_hostname, service: service_uri(opts)}]
  end

  defp flared_opts(opts) do
    {_name, opts1} = Keyword.pop(opts, :name)
    {_hostname, opts2} = Keyword.pop(opts1, :hostname)
    {_scheme, opts3} = Keyword.pop(opts2, :scheme)
    {_service_domain, opts4} = Keyword.pop(opts3, :service_domain)
    {_service_port, rest} = Keyword.pop(opts4, :service_port)
    rest
  end

  defp service_uri(opts) do
    scheme = opts[:scheme] || @default_scheme
    service_domain = opts[:service_domain] || @default_service_domain
    service_port = opts[:service_port] || @default_service_port

    if scheme in [:http, :https] do
      "#{scheme}://#{service_domain}:#{service_port}"
    else
      raise "Expected scheme to be http or https, got: #{scheme}"
    end
  end
end
