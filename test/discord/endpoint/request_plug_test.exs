defmodule Discord.Endpoint.RequestPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Discord.Endpoint.RequestPlug

  @opts RequestPlug.init([])

  setup_all do
    start_supervised!({Discord.Gateways, []})
    start_supervised!({Discord.Webhooks, []})
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

  test "GET /gateways/:name/events returns 404 (route removed)" do
    conn = RequestPlug.call(conn(:get, "/gateways/main/events"), @opts)

    assert conn.status == 404
  end

  test "GET /gateways/:name/events/:type returns 404 (route removed)" do
    conn = RequestPlug.call(conn(:get, "/gateways/main/events/MESSAGE_CREATE"), @opts)

    assert conn.status == 404
  end

  test "DELETE /gateways/:name/events returns 404 (route removed)" do
    conn = RequestPlug.call(conn(:delete, "/gateways/main/events"), @opts)

    assert conn.status == 404
  end

  test "old /events route returns 404" do
    conn = RequestPlug.call(conn(:get, "/events"), @opts)

    assert conn.status == 404
    assert conn.resp_body == ~s({"error":"not_found"})
  end

  test "POST /webhooks dispatches through to WebhooksPlug and broadcasts to subscribers" do
    :ok = Discord.Webhooks.subscribe()

    on_exit(fn -> Discord.Webhooks.unsubscribe() end)

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
    assert_receive {:webhook_event, %{type: "APPLICATION_AUTHORIZED"}}, 100
  end
end
