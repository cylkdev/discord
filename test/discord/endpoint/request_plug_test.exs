defmodule Discord.Endpoint.RequestPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Discord.Endpoint.RequestPlug
  alias Discord.Gateways.EventBuffer
  alias Discord.Webhooks.EventBuffer, as: WebhookEventBuffer

  @opts RequestPlug.init([])

  setup do
    EventBuffer.clear()
    WebhookEventBuffer.clear()
    :ok
  end

  test "GET /gateways/health returns ok with empty gateways map when none are running" do
    conn = RequestPlug.call(conn(:get, "/gateways/health"), @opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok", "gateways" => []}
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "GET /events returns buffered events" do
    EventBuffer.push(%{type: "MESSAGE_CREATE", seq: 1})
    EventBuffer.push(%{type: "READY", seq: 2})

    conn = RequestPlug.call(conn(:get, "/events"), @opts)

    assert conn.status == 200

    assert %{"events" => [%{"type" => "READY"}, %{"type" => "MESSAGE_CREATE"}]} =
             Jason.decode!(conn.resp_body)
  end

  test "unknown route returns 404 JSON" do
    conn = RequestPlug.call(conn(:get, "/missing"), @opts)

    assert conn.status == 404
    assert conn.resp_body == ~s({"error":"not_found"})
  end

  test "non-GET method on /events returns 405" do
    conn = RequestPlug.call(conn(:post, "/events"), @opts)
    assert conn.status == 405
    assert conn.resp_body == ~s({"error":"method_not_allowed"})
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

  test "POST /webhooks without configured public key returns 503" do
    body = ~s({"type":0})

    conn =
      :post
      |> conn("/webhooks", body)
      |> RequestPlug.call(@opts)

    assert conn.status == 503
    assert conn.resp_body == ~s({"error":"webhooks_not_configured"})
  end
end
