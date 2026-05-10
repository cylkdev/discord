defmodule Discord.Endpoint.GatewayPlug do
  @moduledoc """
  HTTP API for gateway observability and control.

      GET /gateways                     -> list live gateway connection info
      GET /gateways/:name               -> one live gateway connection
      GET /gateways/:name/events        -> buffered events for one connection
      GET /gateways/:name/events/:type  -> buffered events filtered by one type

  Observable behaviour:

    * Read routes are unsigned.
    * Write routes are signed and rejected before any mutation when the
      signature is missing, invalid, stale, or unconfigured.
    * Old `/events` routes are not supported here.
  """

  @behaviour Plug

  alias Discord.Endpoint.{GatewayWriteAuth, Response}
  alias Plug.Conn

  @logger_prefix "Discord.Endpoint.GatewayPlug"

  @impl true
  def init(opts) do
    [
      gateway_hmac_secret: Keyword.get(opts, :gateway_hmac_secret),
      gateway_public_key: Keyword.get(opts, :gateway_public_key)
    ]
  end

  @impl true
  def call(%Conn{method: "GET", path_info: ["gateways"]} = conn, _opts) do
    Response.send_json(conn, 200, %{gateways: Discord.Gateways.list_connection_info()})
  end

  def call(%Conn{method: "GET", path_info: ["gateways", name]} = conn, _opts) do
    case Discord.Gateways.connection_info(name) do
      {:ok, info} -> Response.send_json(conn, 200, info)
      {:error, :not_found} -> Response.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def call(%Conn{method: "GET", path_info: ["gateways", name, "events"]} = conn, _opts) do
    conn = Conn.fetch_query_params(conn)
    events = Discord.Gateways.events(name, limit: parse_limit(conn.params["limit"]))
    Response.send_json(conn, 200, %{events: events})
  end

  def call(%Conn{method: "GET", path_info: ["gateways", name, "events", type]} = conn, _opts) do
    conn = Conn.fetch_query_params(conn)

    if type in Discord.Gateways.supported_event_types() do
      events = Discord.Gateways.events(name, type, limit: parse_limit(conn.params["limit"]))
      Response.send_json(conn, 200, %{events: events})
    else
      Response.send_json(conn, 400, %{
        error: "unsupported_event_type",
        supported_event_types: Discord.Gateways.supported_event_types()
      })
    end
  end

  def call(%Conn{method: "POST", path_info: ["gateways"]} = conn, opts) do
    with_verified_json(conn, opts, fn conn, payload ->
      with {:ok, name} <- fetch_required_string(payload, "name"),
           {:ok, token} <- fetch_required_string(payload, "token"),
           {:ok, connect_opts} <- normalize_connect_opts(payload) do
        case Discord.Gateways.connect(name, token, connect_opts) do
          {:ok, _pid} ->
            case Discord.Gateways.connection_info(name) do
              {:ok, info} -> Response.send_json(conn, 201, info)
              {:error, :not_found} -> Response.send_json(conn, 404, %{error: "not_found"})
            end

          {:error, {:already_started, _pid}} ->
            Response.send_json(conn, 409, %{error: "already_started"})

          {:error, reason} ->
            Response.send_json(conn, 500, %{error: "connect_failed", reason: inspect(reason)})
        end
      else
        {:error, :invalid_request} ->
          Response.send_json(conn, 400, %{error: "invalid_request"})
      end
    end)
  end

  def call(%Conn{method: "DELETE", path_info: ["gateways", name]} = conn, opts) do
    with_verified_body(conn, opts, fn conn, _body ->
      case Discord.Gateways.disconnect(name) do
        :ok -> Conn.send_resp(conn, 204, "")
        {:error, :not_found} -> Response.send_json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  def call(%Conn{method: "DELETE", path_info: ["gateways", name, "events"]} = conn, opts) do
    with_verified_body(conn, opts, fn conn, _body ->
      :ok = Discord.Gateways.clear_events(name)
      Conn.send_resp(conn, 204, "")
    end)
  end

  def call(%Conn{method: "POST", path_info: ["gateways", name, "messages"]} = conn, opts) do
    with_verified_json(conn, opts, fn conn, payload ->
      with {:ok, channel_id} <- fetch_required_string(payload, "channel_id"),
           {:ok, message_payload} <- fetch_required_map(payload, "payload") do
        case Discord.Gateways.send_message(name, channel_id, message_payload) do
          {:ok, body} ->
            Response.send_json(conn, 200, body)

          {:error, :not_connected} ->
            Response.send_json(conn, 404, %{error: "not_found"})

          {:error, {:http_error, status, body}} ->
            Response.send_json(conn, status, body)

          {:error, reason} ->
            Response.send_json(conn, 502, %{error: "upstream_error", reason: inspect(reason)})
        end
      else
        {:error, :invalid_request} ->
          Response.send_json(conn, 400, %{error: "invalid_request"})
      end
    end)
  end

  def call(%Conn{method: "POST", path_info: ["gateways", name, "replies"]} = conn, opts) do
    with_verified_json(conn, opts, fn conn, payload ->
      with {:ok, channel_id} <- fetch_required_string(payload, "channel_id"),
           {:ok, message_id} <- fetch_required_string(payload, "message_id"),
           {:ok, message_payload} <- fetch_required_map(payload, "payload") do
        case Discord.Gateways.reply(name, channel_id, message_id, message_payload) do
          {:ok, body} ->
            Response.send_json(conn, 200, body)

          {:error, :not_connected} ->
            Response.send_json(conn, 404, %{error: "not_found"})

          {:error, {:http_error, status, body}} ->
            Response.send_json(conn, status, body)

          {:error, reason} ->
            Response.send_json(conn, 502, %{error: "upstream_error", reason: inspect(reason)})
        end
      else
        {:error, :invalid_request} ->
          Response.send_json(conn, 400, %{error: "invalid_request"})
      end
    end)
  end

  def call(
        %Conn{path_info: ["gateways"]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(
        %Conn{path_info: ["gateways", _name]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(
        %Conn{path_info: ["gateways", _name, "events"]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(
        %Conn{path_info: ["gateways", _name, "events", _type]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(
        %Conn{path_info: ["gateways", _name, "messages"]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(
        %Conn{path_info: ["gateways", _name, "replies"]} = conn,
        _opts
      ) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(conn, _opts) do
    Discord.Log.debug(@logger_prefix, "unrouted gateway path",
      method: conn.method,
      path_info: conn.path_info
    )

    Response.send_json(conn, 404, %{error: "not_found"})
  end

  defp with_verified_body(conn, opts, fun) do
    {:ok, body, conn} = read_full_body(conn)

    case verify_write_request(conn, body, opts) do
      :ok -> fun.(conn, body)
      {:error, reason} -> write_auth_error(conn, reason)
    end
  end

  defp with_verified_json(conn, opts, fun) do
    with_verified_body(conn, opts, fn conn, body ->
      case JSON.decode(body) do
        {:ok, payload} when is_map(payload) -> fun.(conn, payload)
        _ -> Response.send_json(conn, 400, %{error: "invalid_json"})
      end
    end)
  end

  defp write_auth_error(conn, :write_auth_not_configured) do
    Response.send_json(conn, 503, %{error: "write_auth_not_configured"})
  end

  defp write_auth_error(conn, :missing_signature) do
    Response.send_json(conn, 401, %{error: "missing_signature"})
  end

  defp write_auth_error(conn, :invalid_signature) do
    Response.send_json(conn, 401, %{error: "invalid_signature"})
  end

  defp write_auth_error(conn, :stale_timestamp) do
    Response.send_json(conn, 401, %{error: "stale_timestamp"})
  end

  defp fetch_required_string(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp fetch_required_map(payload, key) do
    case Map.get(payload, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp verify_write_request(conn, body, opts) do
    with :ok <- ensure_write_auth_configured(opts),
         {:ok, timestamp} <- fetch_required_header(conn, "x-gateway-timestamp"),
         :ok <- GatewayWriteAuth.verify_timestamp(timestamp) do
      canonical = canonical_payload(timestamp, conn.method, conn.request_path, body)

      hmac_result = verify_hmac_signature(conn, canonical, opts)
      ed25519_result = verify_ed25519_signature(conn, canonical, opts)

      case {hmac_result, ed25519_result} do
        {:ok, _} ->
          :ok

        {_, :ok} ->
          :ok

        {{:error, :invalid_signature}, _} ->
          {:error, :invalid_signature}

        {_, {:error, :invalid_signature}} ->
          {:error, :invalid_signature}

        {{:error, :missing_signature}, {:error, :missing_signature}} ->
          {:error, :missing_signature}

        {{:error, :missing_signature}, :not_configured} ->
          {:error, :missing_signature}

        {:not_configured, {:error, :missing_signature}} ->
          {:error, :missing_signature}

        {:not_configured, :not_configured} ->
          {:error, :write_auth_not_configured}
      end
    else
      {:error, :write_auth_not_configured} -> {:error, :write_auth_not_configured}
      {:error, :missing_signature} -> {:error, :missing_signature}
      {:error, :invalid_signature} -> {:error, :invalid_signature}
      {:error, :stale_timestamp} -> {:error, :stale_timestamp}
    end
  end

  defp verify_hmac_signature(conn, canonical, opts) do
    case gateway_hmac_secret(opts) do
      nil ->
        :not_configured

      secret ->
        with {:ok, signature} <- fetch_required_header(conn, "x-gateway-signature-hmac-sha256") do
          GatewayWriteAuth.verify_hmac_sha256(canonical, signature, secret)
        end
    end
  end

  defp verify_ed25519_signature(conn, canonical, opts) do
    case gateway_public_key(opts) do
      nil ->
        :not_configured

      public_key ->
        with {:ok, signature} <- fetch_required_header(conn, "x-gateway-signature-ed25519") do
          GatewayWriteAuth.verify_ed25519(canonical, signature, public_key)
        end
    end
  end

  defp ensure_write_auth_configured(opts) do
    if gateway_hmac_secret(opts) || gateway_public_key(opts) do
      :ok
    else
      {:error, :write_auth_not_configured}
    end
  end

  defp fetch_required_header(conn, header_name) do
    case Conn.get_req_header(conn, header_name) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_signature}
    end
  end

  defp normalize_connect_opts(%{"intents" => intents}) when is_list(intents) do
    normalize_intents(intents, [])
  end

  defp normalize_connect_opts(%{"intents" => _invalid}), do: {:error, :invalid_request}
  defp normalize_connect_opts(_payload), do: {:ok, []}

  defp normalize_intents([], acc), do: {:ok, [intents: Enum.reverse(acc)]}

  defp normalize_intents(["guilds" | rest], acc), do: normalize_intents(rest, [:guilds | acc])

  defp normalize_intents(["guild_messages" | rest], acc),
    do: normalize_intents(rest, [:guild_messages | acc])

  defp normalize_intents(["message_content" | rest], acc),
    do: normalize_intents(rest, [:message_content | acc])

  defp normalize_intents(_intents, _acc), do: {:error, :invalid_request}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

  defp canonical_payload(timestamp, method, request_path, body) do
    Enum.join([timestamp, String.upcase(method), request_path, body], "\n")
  end

  defp gateway_hmac_secret(opts) do
    case Keyword.get(opts, :gateway_hmac_secret) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp gateway_public_key(opts) do
    case Keyword.get(opts, :gateway_public_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp read_full_body(conn, acc \\ "") do
    case Conn.read_body(conn) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, reason} -> {:error, reason}
    end
  end
end
