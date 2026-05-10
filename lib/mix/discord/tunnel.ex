defmodule Mix.Discord.Tunnel do
  @moduledoc false

  # Shared implementation for the subsystem-specific Cloudflare tunnel Mix
  # tasks (`mix discord.gateway.tunnel`, `mix discord.webhook.tunnel`).
  #
  # Each task supplies its own subsystem-flavoured `name`/`hostname`
  # defaults and delegates the actual work — option parsing, route
  # construction, `:flared` startup, and `Flared.MixTask.run_remote/3`
  # invocation — to `run/2`.

  @logger_prefix "Mix.Discord.Tunnel"

  @switches [
    name: :string,
    hostname: :string,
    scheme: :string,
    service_domain: :string,
    service_port: :integer
  ]

  @default_scheme :http
  @default_service_domain "localhost"
  @default_service_port 4000

  @doc """
  Parses tunnel CLI args, ensures `:flared` is started, and runs a
  remote-managed Cloudflare tunnel via `Flared.MixTask.run_remote/3`.

  `defaults` must supply subsystem-specific `:name` and `:hostname`
  values. Other options (`--scheme`, `--service-domain`,
  `--service-port`) fall back to non-subsystem-specific defaults defined
  in this module.
  """
  @spec run([String.t()], keyword()) :: :ok | no_return()
  def run(args, defaults) when is_list(args) and is_list(defaults) do
    {:ok, _started} = Application.ensure_all_started(:flared)

    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    opts = normalize(opts)

    default_name = Keyword.fetch!(defaults, :name)
    default_hostname = Keyword.fetch!(defaults, :hostname)

    name = opts[:name] || default_name
    hostname = opts[:hostname] || default_hostname

    Discord.Log.info(@logger_prefix, "provisioning tunnel",
      name: name,
      hostname: hostname,
      service: service_uri(opts)
    )

    case Flared.MixTask.run_remote(name, routes(opts, default_hostname), flared_opts(opts)) do
      :ok ->
        Discord.Log.info(@logger_prefix, "tunnel exited cleanly", name: name)

      {:error, reason} ->
        Discord.Log.error(@logger_prefix, "tunnel failed",
          name: name,
          reason: inspect(reason)
        )

        Mix.raise("Cloudflare tunnel failed: #{inspect(reason)}")
    end
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
    Discord.Log.error(@logger_prefix, "invalid scheme", scheme: other)
    Mix.raise(~s(--scheme must be "http" or "https", got: #{inspect(other)}))
  end

  defp routes(opts, default_hostname) do
    [%{hostname: opts[:hostname] || default_hostname, service: service_uri(opts)}]
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
