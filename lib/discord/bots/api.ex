defmodule Discord.Bots.API do
  @moduledoc """
  Discord Bot REST API client.

  Observable behaviour:

    * Never reads tokens from application config or process state.
    * Performs one HTTP request per function call.
    * Returns `{:ok, decoded_body}` on 2xx responses.
    * Returns `{:error, {:http_error, status, decoded_body}}` on Discord
      non-2xx responses.
    * Returns `{:error, reason}` on transport failures.
  """

  alias Discord.HTTP

  @logger_prefix "Discord.Bots.API"

  @base_url "https://discord.com/api/v10"

  @type message_payload :: %{optional(String.t()) => term()}

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
  @spec get_gateway_bot(String.t()) :: {:ok, map()} | {:error, term()}
  def get_gateway_bot(token) when is_binary(token) do
    Discord.Log.debug(@logger_prefix, "GET /gateway/bot")

    "/gateway/bot"
    |> get(token)
    |> unwrap()
  end

  @doc """
  `POST /channels/:channel_id/messages` — creates a Discord message.

  Parameters:

    * `token` - Discord bot token.
    * `channel_id` - Discord channel id string.
    * `payload` - JSON object forwarded to Discord as the create-message body.

  Side effects:

    * Performs one HTTPS POST to Discord.

  ## Examples

      iex> Discord.Bots.API.create_message("Bot abc123", "123", %{"content" => "pong"})
      {:ok, %{"id" => "9002", "channel_id" => "123", "content" => "pong"}}
  """
  @spec create_message(String.t(), String.t(), message_payload()) ::
          {:ok, map()} | {:error, term()}
  def create_message(token, channel_id, payload)
      when is_binary(token) and is_binary(channel_id) and is_map(payload) do
    "/channels/#{channel_id}/messages"
    |> post(token, payload)
    |> unwrap()
  end

  @doc """
  `POST /channels/:channel_id/messages` — creates a Discord reply.

  Parameters:

    * `token` - Discord bot token.
    * `channel_id` - Discord channel id string.
    * `message_id` - Discord message id string to reference.
    * `payload` - JSON object forwarded to Discord as the create-message body.

  Observable behaviour:

    * Always writes `message_reference.message_id = message_id`.
    * Overwrites any caller-supplied `message_reference`.

  Side effects:

    * Performs one HTTPS POST to Discord.

  ## Examples

      iex> Discord.Bots.API.reply_to_message("Bot abc123", "123", "9001", %{"content" => "pong"})
      {:ok,
       %{
         "id" => "9003",
         "channel_id" => "123",
         "content" => "pong",
         "message_reference" => %{"message_id" => "9001"}
       }}
  """
  @spec reply_to_message(String.t(), String.t(), String.t(), message_payload()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_message(token, channel_id, message_id, payload)
      when is_binary(token) and is_binary(channel_id) and is_binary(message_id) and
             is_map(payload) do
    payload = Map.put(payload, "message_reference", %{"message_id" => message_id})
    create_message(token, channel_id, payload)
  end

  defp get(path, token) do
    HTTP.get(@base_url <> path, auth_headers(token))
  end

  defp post(path, token, payload) do
    HTTP.post(@base_url <> path, payload, auth_headers(token))
  end

  defp auth_headers(token), do: [{"authorization", "Bot " <> token}]

  defp unwrap({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}

  defp unwrap({:ok, %{status: status, body: body}}) do
    Discord.Log.warning(@logger_prefix, "non-2xx response", status: status)
    {:error, {:http_error, status, body}}
  end

  defp unwrap({:error, reason}) do
    Discord.Log.error(@logger_prefix, "transport error", reason: reason)
    {:error, reason}
  end
end
