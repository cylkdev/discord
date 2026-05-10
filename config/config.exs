import Config

config :logger, level: :debug

server_enabled? =
  case System.get_env("DISCORD_SERVER_ENABLED") do
    nil -> Mix.env() !== :test
    "true" -> true
    _ -> false
  end

config :discord,
  server_enabled: server_enabled?

config :flared,
  account_id: "<DISCORD_CLOUDFLARE_TUNNEL_ACCOUNT_ID>",
  api_token: "<DISCORD_CLOUDFLARE_TUNNEL_API_TOKEN>"

if File.exists?(Path.expand("config.secrets.exs", __DIR__)) do
  import_config "config.secrets.exs"
end
