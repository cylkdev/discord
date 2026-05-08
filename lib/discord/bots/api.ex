defmodule Discord.Bots.API do
  @moduledoc """
  Discord Bot REST API client.

  The bot token is an explicit argument on every call so callers
  manage their own credential lifecycle — no module-level config,
  no implicit process state.

  Successful responses are unwrapped to `{:ok, body}`. Non-2xx
  responses become `{:error, {:http_error, status, body}}`.
  Transport failures pass through as `{:error, reason}`.
  """

  alias Discord.HTTP

  @base_url "https://discord.com/api/v10"

  @doc """
  `GET /gateway/bot` — returns the gateway WebSocket URL, the
  recommended shard count, and the bot's session-start limits.

  Equivalent to:

      curl -sS https://discord.com/api/v10/gateway/bot \\
        -H "Authorization: Bot $DISCORD_BOT_TOKEN"

  ## Examples

      iex> Discord.Bots.API.get_gateway_bot(token)
      {:ok, %{
        "url" => "wss://gateway.discord.gg",
        "shards" => 1,
        "session_start_limit" => %{
          "total" => 1000,
          "remaining" => 999,
          "reset_after" => 86_400_000,
          "max_concurrency" => 1
        }
      }}
  """
  def get_gateway_bot(token) when is_binary(token) do
    "/gateway/bot"
    |> get(token)
    |> unwrap()
  end

  defp get(path, token) do
    HTTP.get(@base_url <> path, auth_headers(token))
  end

  defp auth_headers(token), do: [{"authorization", "Bot " <> token}]

  defp unwrap({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp unwrap({:ok, %{status: status, body: body}}), do: {:error, {:http_error, status, body}}
  defp unwrap({:error, reason}), do: {:error, reason}
end
