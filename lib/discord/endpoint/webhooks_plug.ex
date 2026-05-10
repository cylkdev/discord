defmodule Discord.Endpoint.WebhooksPlug do
  @moduledoc """
  Receives Discord webhook event deliveries.

      POST /webhooks  -> 204 (PING handshake or accepted event)
                         401 invalid_signature
                         400 invalid_json
                         503 webhooks_not_configured
                         405 method_not_allowed

  Discord posts a JSON envelope of the form

      {"version": 1, "application_id": "...", "type": 0|1, "event": {...}}

  with the headers `X-Signature-Ed25519` and `X-Signature-Timestamp`. The
  signature covers `timestamp <> raw_body` under the application's public
  key. Discord performs automated probes with intentionally-bad signatures
  to confirm the endpoint enforces verification — failing those probes
  causes Discord to disable the URL.

  Responses must arrive within 3 seconds; delivery is retried with
  exponential backoff for up to 10 minutes otherwise.
  """

  @behaviour Plug

  alias Discord.Endpoint.Response
  alias Discord.Webhooks.{EventBuffer, Signature}
  alias Plug.Conn

  @logger_prefix "Discord.Endpoint.WebhooksPlug"

  @impl true
  def init(opts) do
    %{public_key: normalise_key(Keyword.get(opts, :public_key))}
  end

  @impl true
  def call(%Conn{method: "POST", path_info: ["webhooks"]} = conn, %{public_key: nil}) do
    Discord.Log.warning(@logger_prefix, "webhooks not configured — public_key missing")
    Response.send_json(conn, 503, %{error: "webhooks_not_configured"})
  end

  def call(%Conn{method: "POST", path_info: ["webhooks"]} = conn, %{public_key: public_key}) do
    handle_post(conn, public_key)
  end

  def call(%Conn{path_info: ["webhooks"], method: method} = conn, _opts) do
    Discord.Log.warning(@logger_prefix, "method not allowed", method: method)
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(conn, _opts) do
    Discord.Log.debug(@logger_prefix, "unrouted webhook path", path_info: conn.path_info)
    Response.send_json(conn, 404, %{error: "not_found"})
  end

  defp normalise_key(key) when is_binary(key) and key != "", do: key
  defp normalise_key(_), do: nil

  defp handle_post(conn, public_key) do
    {:ok, body, conn} = read_full_body(conn)
    Discord.Log.debug(@logger_prefix, "POST /webhooks received", body_size: byte_size(body))

    with {:ok, signature} <- header(conn, "x-signature-ed25519"),
         {:ok, timestamp} <- header(conn, "x-signature-timestamp"),
         :ok <- Signature.verify(body, timestamp, signature, public_key),
         {:ok, payload} <- decode_json(body) do
      Discord.Log.debug(
        @logger_prefix,
        "payload decoded\n" <> inspect(payload, pretty: true, limit: :infinity),
        type: payload["type"]
      )

      dispatch(conn, payload)
    else
      {:error, :missing_header} ->
        Discord.Log.warning(@logger_prefix, "rejected — missing signature header")
        Response.send_json(conn, 401, %{error: "invalid_signature"})

      {:error, :invalid_signature} ->
        Discord.Log.warning(@logger_prefix, "rejected — invalid signature")
        Response.send_json(conn, 401, %{error: "invalid_signature"})

      {:error, :malformed_signature} ->
        Discord.Log.warning(@logger_prefix, "rejected — malformed signature header")
        Response.send_json(conn, 401, %{error: "invalid_signature"})

      {:error, :malformed_public_key} ->
        Discord.Log.error(
          @logger_prefix,
          "rejected — malformed public key (webhooks misconfigured)"
        )

        Response.send_json(conn, 503, %{error: "webhooks_not_configured"})

      {:error, :invalid_json} ->
        Discord.Log.warning(@logger_prefix, "rejected — invalid json body",
          body_size: byte_size(body)
        )

        Response.send_json(conn, 400, %{error: "invalid_json"})
    end
  end

  defp dispatch(conn, %{"type" => 0} = payload) do
    # PING handshake. Discord requires 204 with a valid Content-Type header.
    Discord.Log.info(
      @logger_prefix,
      "PING handshake — replying 204\n" <> inspect(payload, pretty: true, limit: :infinity)
    )

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(204, "")
  end

  defp dispatch(conn, %{"type" => 1, "event" => event} = payload) when is_map(event) do
    Discord.Log.info(
      @logger_prefix,
      "webhook event received\n" <> inspect(payload, pretty: true, limit: :infinity),
      type: event["type"],
      application_id: payload["application_id"]
    )

    EventBuffer.push(%{
      type: event["type"],
      received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: payload
    })

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(204, "")
  end

  defp dispatch(conn, payload) do
    # Forward-compat: unknown outer type, or type 1 without an event object.
    # Ack to avoid Discord retries; we'll surface details in logs as the
    # webhooks API evolves.
    Discord.Log.warning(
      @logger_prefix,
      "unknown payload shape — acked\n" <> inspect(payload, pretty: true, limit: :infinity),
      type: payload["type"],
      keys: Map.keys(payload)
    )

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(204, "")
  end

  defp header(conn, name) do
    case Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_header}
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp read_full_body(conn, acc \\ "") do
    case Conn.read_body(conn) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _reason} = err -> err
    end
  end
end
