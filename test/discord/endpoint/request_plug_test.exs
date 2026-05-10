defmodule Discord.Endpoint.RequestPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Discord.Endpoint.RequestPlug
  alias Discord.Gateways.EventBuffer
  alias Discord.Webhooks.EventBuffer, as: WebhookEventBuffer

  @opts RequestPlug.init([])

  setup_all do
    start_supervised!({Discord.Gateways, []})
    start_supervised!({Discord.Webhooks, []})
    :ok
  end

  setup do
    EventBuffer.clear()
    WebhookEventBuffer.clear()
    :ok
  end

  test "GET /health returns ok with empty gateways when none are running" do
    conn = RequestPlug.call(conn(:get, "/health"), @opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok", "gateways" => []}
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "GET /gateways returns live gateway info" do
    conn = RequestPlug.call(conn(:get, "/gateways"), @opts)

    assert conn.status == 200
    assert %{"gateways" => []} = Jason.decode!(conn.resp_body)
  end

  test "GET /gateways/:name/events returns buffered events for one connection" do
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 1, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 2, data: %{}})

    EventBuffer.push("secondary", %{
      connection: :secondary,
      type: "MESSAGE_DELETE",
      seq: 3,
      data: %{}
    })

    conn = RequestPlug.call(conn(:get, "/gateways/main/events"), @opts)

    assert conn.status == 200

    assert %{
             "events" => [
               %{"type" => "READY", "connection" => "main"},
               %{"type" => "MESSAGE_CREATE", "connection" => "main"}
             ]
           } = Jason.decode!(conn.resp_body)
  end

  test "GET /gateways/:name/events/:type returns filtered events" do
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 1, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "READY", seq: 2, data: %{}})
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 3, data: %{}})

    conn = RequestPlug.call(conn(:get, "/gateways/main/events/MESSAGE_CREATE?limit=1"), @opts)

    assert conn.status == 200

    assert %{"events" => [%{"type" => "MESSAGE_CREATE", "seq" => 3}]} =
             Jason.decode!(conn.resp_body)
  end

  test "GET /gateways/:name/events/:type returns 400 for unsupported event types" do
    conn = RequestPlug.call(conn(:get, "/gateways/main/events/THREAD_CREATE"), @opts)

    assert conn.status == 400

    assert %{
             "error" => "unsupported_event_type",
             "supported_event_types" => supported
           } = Jason.decode!(conn.resp_body)

    assert "MESSAGE_CREATE" in supported
  end

  test "old /events route returns 404" do
    conn = RequestPlug.call(conn(:get, "/events"), @opts)

    assert conn.status == 404
    assert conn.resp_body == ~s({"error":"not_found"})
  end

  test "DELETE /gateways/:name/events rejects writes when auth is not configured" do
    conn = RequestPlug.call(conn(:delete, "/gateways/main/events"), @opts)

    assert conn.status == 503
    assert conn.resp_body == ~s({"error":"write_auth_not_configured"})
  end

  test "DELETE /gateways/:name/events accepts a valid HMAC signature" do
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 1, data: %{}})
    opts = RequestPlug.init(gateway_hmac_secret: "top-secret")

    conn =
      :delete
      |> conn("/gateways/main/events")
      |> sign_hmac("top-secret")
      |> RequestPlug.call(opts)

    assert conn.status == 204
    assert Discord.Gateways.events(:main) == []
  end

  test "DELETE /gateways/:name/events accepts a valid Ed25519 signature" do
    EventBuffer.push("main", %{connection: :main, type: "MESSAGE_CREATE", seq: 1, data: %{}})

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    opts = RequestPlug.init(gateway_public_key: Base.encode16(public_key, case: :lower))

    conn =
      :delete
      |> conn("/gateways/main/events")
      |> sign_ed25519(private_key)
      |> RequestPlug.call(opts)

    assert conn.status == 204
    assert Discord.Gateways.events(:main) == []
  end

  test "DELETE /gateways/:name/events rejects invalid signatures" do
    opts = RequestPlug.init(gateway_hmac_secret: "top-secret")

    conn =
      :delete
      |> conn("/gateways/main/events")
      |> put_req_header("x-gateway-timestamp", Integer.to_string(System.system_time(:second)))
      |> put_req_header("x-gateway-signature-hmac-sha256", String.duplicate("00", 32))
      |> RequestPlug.call(opts)

    assert conn.status == 401
    assert conn.resp_body == ~s({"error":"invalid_signature"})
  end

  test "DELETE /gateways/:name/events rejects stale timestamps" do
    opts = RequestPlug.init(gateway_hmac_secret: "top-secret")
    timestamp = Integer.to_string(System.system_time(:second) - 301)

    signature =
      hmac_signature("DELETE", "/gateways/main/events", "", timestamp, "top-secret")

    conn =
      :delete
      |> conn("/gateways/main/events")
      |> put_req_header("x-gateway-timestamp", timestamp)
      |> put_req_header("x-gateway-signature-hmac-sha256", signature)
      |> RequestPlug.call(opts)

    assert conn.status == 401
    assert conn.resp_body == ~s({"error":"stale_timestamp"})
  end

  test "POST /webhooks dispatches through to WebhooksPlug" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    public_key_hex = Base.encode16(pub, case: :lower)
    opts = RequestPlug.init(public_key: public_key_hex)

    body =
      ~s({"version":1,"application_id":"1","type":1,"event":{"type":"APPLICATION_AUTHORIZED","timestamp":"2024-10-18T14:42:53.064834","data":{"integration_type":1,"scopes":["applications.commands"],"user":{}}}})

    timestamp = Integer.to_string(System.system_time(:second))
    sig = :crypto.sign(:eddsa, :none, timestamp <> body, [priv, :ed25519])

    conn =
      :post
      |> conn("/webhooks", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-signature-ed25519", Base.encode16(sig, case: :lower))
      |> put_req_header("x-signature-timestamp", timestamp)
      |> RequestPlug.call(opts)

    assert conn.status == 204
    assert [%{type: "APPLICATION_AUTHORIZED"}] = WebhookEventBuffer.list()
  end

  defp sign_hmac(conn, secret) do
    body = conn.assigns[:raw_body] || ""
    timestamp = Integer.to_string(System.system_time(:second))
    signature = hmac_signature(conn.method, conn.request_path, body, timestamp, secret)

    conn
    |> put_req_header("x-gateway-timestamp", timestamp)
    |> put_req_header("x-gateway-signature-hmac-sha256", signature)
  end

  defp sign_ed25519(conn, private_key) do
    body = conn.assigns[:raw_body] || ""
    timestamp = Integer.to_string(System.system_time(:second))
    canonical = canonical_payload(conn.method, conn.request_path, body, timestamp)

    signature =
      :crypto.sign(:eddsa, :none, canonical, [private_key, :ed25519])
      |> Base.encode16(case: :lower)

    conn
    |> put_req_header("x-gateway-timestamp", timestamp)
    |> put_req_header("x-gateway-signature-ed25519", signature)
  end

  defp hmac_signature(method, request_path, body, timestamp, secret) do
    canonical_payload(method, request_path, body, timestamp)
    |> then(&:crypto.mac(:hmac, :sha256, secret, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_payload(method, request_path, body, timestamp) do
    Enum.join([timestamp, String.upcase(method), request_path, body], "\n")
  end
end
