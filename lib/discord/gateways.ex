defmodule Discord.Gateways do
  @moduledoc """
  Public API for named Discord Gateway connections.

  Observable behaviour:

    * Starts and stops named Discord Gateway websocket connections.
    * Requests `[:guilds, :guild_messages, :message_content]` by default.
    * Broadcasts every dispatch event over an in-process pubsub. The library
      itself does not store events; consumers subscribe and decide what to
      keep.
    * Stores bot identity from the `READY` event.
    * `disconnect/1` closes the websocket.
    * `send_message/3` and `reply/4` perform outbound Discord REST requests
      using the token attached to the named connection.
    * `connect/3` only confirms that the local worker started; Discord
      authentication still completes asynchronously.

  Open a connection by passing the raw bot token explicitly, then subscribe
  to receive dispatch events as regular process messages:

      Discord.Gateways.subscribe(:main)
      Discord.Gateways.connect(:main, "YOUR_BOT_TOKEN")
      # then in the subscribed process:
      # receive: {:gateway_event, %{type: "MESSAGE_CREATE", ...}}

  Subscribe to one event type only:

      Discord.Gateways.subscribe(:main, "MESSAGE_CREATE")

  The token must be a string. There is no implicit token loading from
  application config or environment variables.
  """

  use Supervisor

  alias Discord.Bots.API
  alias Discord.Gateways.{PubSub, WebSocket, WebSocketRegistry, WebSocketSupervisor}

  @logger_prefix "Discord.Gateways"
  @default_intents [:guilds, :guild_messages, :message_content]

  @type gateway_name :: atom() | String.t()
  @type intent_name :: :guilds | :guild_messages | :message_content

  @type gateway_event :: %{
          connection: gateway_name(),
          type: String.t(),
          seq: non_neg_integer() | nil,
          received_at: String.t(),
          data: map()
        }

  @type connection_info :: %{
          name: gateway_name(),
          connected: boolean(),
          status: :connecting | :ready | :reconnecting | :resuming,
          bot_user_id: String.t() | nil,
          bot_username: String.t() | nil,
          intents: [intent_name()],
          session_id: String.t() | nil,
          resume_gateway_url: String.t() | nil
        }

  @type message_payload :: %{optional(String.t()) => term()}

  @type discord_result ::
          {:ok, map()}
          | {:error, :not_connected | {:http_error, integer(), term()} | term()}

  @doc """
  Returns the default gateway intents used when `connect/3` is called without
  an explicit `:intents` option.
  """
  @spec default_intents() :: [intent_name()]
  def default_intents, do: @default_intents

  def start_link(opts \\ []) do
    Discord.Log.info(@logger_prefix, "supervisor starting")
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Discord.Gateways.WebSocketRegistry, opts},
      {Discord.Gateways.WebSocketSupervisor, opts},
      {Discord.Gateways.PubSub, opts}
    ]

    Discord.Log.info(
      @logger_prefix,
      "supervision tree initialized children=#{inspect(Enum.map(children, &elem(&1, 0)))}"
    )

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts a Gateway WebSocket connection under the dynamic supervisor, registered
  under `name`.

  Parameters:

    * `name` - connection name. Public APIs accept atoms and strings.
    * `token` - raw Discord bot token.
    * `opts[:intents]` - list of supported gateway intent atoms. When omitted,
      defaults to `default_intents/0`.

  Returns `{:ok, pid}` on success, or `{:error, {:already_started, pid}}` if a
  connection with that name already exists.

  Side effects:

    * Starts a local worker under the gateway dynamic supervisor.
    * Opens a TLS websocket to Discord.
    * Starts heartbeats and begins broadcasting dispatch events to pubsub
      subscribers for the connection.

  The return value only confirms that the local worker started. Discord still
  authenticates the token asynchronously over the websocket session.

  ## Examples

      iex> Discord.Gateways.connect(:main, "abc123")
      {:ok, #PID<0.321.0>}
  """
  @spec connect(gateway_name(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, {:already_started, pid()} | term()}
  def connect(name, token, opts \\ []) when is_binary(token) and token != "" and is_list(opts) do
    Discord.Log.debug(@logger_prefix, "connect requested name=#{inspect(name)}")

    public_name = normalize_name(name)
    connect_opts = opts |> normalize_connect_opts() |> Keyword.put(:public_name, name)

    WebSocketSupervisor.connect(public_name, token, connect_opts)
  end

  @doc """
  Stops the named Gateway connection.

  Parameters:

    * `name` - connection name.

  Returns `:ok` when a live connection existed, or `{:error, :not_found}` when
  there is no live websocket for that name.

  Side effects:

    * Stops the websocket worker for the named connection.
  """
  @spec disconnect(gateway_name()) :: :ok | {:error, :not_found}
  def disconnect(name) do
    Discord.Log.debug(@logger_prefix, "disconnect requested name=#{inspect(name)}")
    WebSocketSupervisor.disconnect(normalize_name(name))
  end

  @doc """
  Returns `true` only when the named connection has reached the Discord `READY`
  state.
  """
  @spec connected?(gateway_name()) :: boolean()
  def connected?(name), do: WebSocket.connected?(name)

  @doc """
  Returns the current public connection snapshot for one live connection.

  The returned map contains the current connection status, stored bot identity,
  requested intents, and resume metadata.
  """
  @spec connection_info(gateway_name()) :: {:ok, connection_info()} | {:error, :not_found}
  def connection_info(name), do: WebSocket.connection_info(name)

  @doc """
  Returns one public connection snapshot per live gateway websocket.
  """
  @spec list_connection_info() :: [connection_info()]
  def list_connection_info do
    list_connections()
    |> Enum.flat_map(fn {name, _pid} ->
      case connection_info(name) do
        {:ok, info} -> [info]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc """
  Subscribes the calling process to every dispatch event for the named
  connection. The subscriber receives `{:gateway_event, event_map}` messages.

  Parameters:

    * `name` - connection name. Atoms and strings are accepted.

  Returns `:ok`. The subscription is auto-released when the calling process
  exits.

  ## Examples

      iex> Discord.Gateways.subscribe(:main)
      :ok
  """
  @spec subscribe(gateway_name()) :: :ok
  def subscribe(name), do: PubSub.subscribe(normalize_name(name))

  @doc """
  Subscribes the calling process to dispatch events of one `type` for the
  named connection. Other event types are not delivered.

  Parameters:

    * `name` - connection name.
    * `type` - Discord dispatch event type string (for example `"MESSAGE_CREATE"`).

  Returns `:ok`.
  """
  @spec subscribe(gateway_name(), String.t()) :: :ok
  def subscribe(name, type) when is_binary(type),
    do: PubSub.subscribe(normalize_name(name), type)

  @doc """
  Unsubscribes the calling process from every-event delivery for the named
  connection.

  Returns `:ok`. Idempotent.
  """
  @spec unsubscribe(gateway_name()) :: :ok
  def unsubscribe(name), do: PubSub.unsubscribe(normalize_name(name))

  @doc """
  Unsubscribes the calling process from a typed subscription.

  Returns `:ok`. Idempotent.
  """
  @spec unsubscribe(gateway_name(), String.t()) :: :ok
  def unsubscribe(name, type) when is_binary(type),
    do: PubSub.unsubscribe(normalize_name(name), type)

  @doc """
  Sends a Discord message using the bot token attached to the named connection.

  Parameters:

    * `name` - connection name.
    * `channel_id` - Discord channel id string.
    * `payload` - JSON object forwarded to Discord's create-message endpoint.

  Returns `{:ok, body}` on a 2xx Discord response, or `{:error, :not_connected}`
  when the named connection is not live.

  Side effects:

    * Performs one HTTPS POST to Discord.

  ## Examples

      iex> Discord.Gateways.send_message(:main, "123", %{"content" => "pong"})
      {:ok, %{"id" => "9002", "channel_id" => "123", "content" => "pong"}}
  """
  @spec send_message(gateway_name(), String.t(), message_payload()) :: discord_result()
  def send_message(name, channel_id, payload)
      when is_binary(channel_id) and is_map(payload) do
    with {:ok, token} <- WebSocket.token(name) do
      API.create_message(token, channel_id, payload)
    end
  end

  @doc """
  Sends a Discord reply using the bot token attached to the named connection.

  Parameters:

    * `name` - connection name.
    * `channel_id` - Discord channel id string.
    * `message_id` - Discord message id string to reference.
    * `payload` - JSON object forwarded to Discord's create-message endpoint.

  Returns the decoded Discord response on success, or `{:error, :not_connected}`
  when the named connection is not live.

  Side effects:

    * Performs one HTTPS POST to Discord.

  ## Examples

      iex> Discord.Gateways.reply(:main, "123", "9001", %{"content" => "pong"})
      {:ok,
       %{
         "id" => "9003",
         "channel_id" => "123",
         "content" => "pong",
         "message_reference" => %{"message_id" => "9001"}
       }}
  """
  @spec reply(gateway_name(), String.t(), String.t(), message_payload()) :: discord_result()
  def reply(name, channel_id, message_id, payload)
      when is_binary(channel_id) and is_binary(message_id) and is_map(payload) do
    with {:ok, token} <- WebSocket.token(name) do
      API.reply_to_message(token, channel_id, message_id, payload)
    end
  end

  @doc """
  Lists every running Gateway connection as `[{name, pid}, ...]`.
  """
  def list_connections do
    connections =
      WebSocketSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_, pid, _, _} when is_pid(pid) ->
          case WebSocketRegistry.keys(pid) do
            [registry_name | _] ->
              case WebSocket.connection_info(registry_name) do
                {:ok, %{name: public_name}} -> [{public_name, pid}]
                {:error, :not_found} -> []
              end

            _ ->
              []
          end

        _ ->
          []
      end)

    Discord.Log.debug(@logger_prefix, "listing connections count=#{length(connections)}")
    connections
  end

  defp normalize_connect_opts(opts) do
    intents =
      opts
      |> Keyword.get(:intents)
      |> normalize_intents()

    Keyword.put(opts, :intents, intents)
  end

  defp normalize_intents(nil), do: default_intents()
  defp normalize_intents([]), do: default_intents()

  defp normalize_intents(intents) when is_list(intents) do
    Enum.map(intents, &normalize_intent/1)
  end

  defp normalize_intent(:guilds), do: :guilds
  defp normalize_intent(:guild_messages), do: :guild_messages
  defp normalize_intent(:message_content), do: :message_content

  defp normalize_intent(intent) do
    raise ArgumentError,
          "unsupported gateway intent #{inspect(intent)}. Supported values: #{inspect(@default_intents)}"
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
end
