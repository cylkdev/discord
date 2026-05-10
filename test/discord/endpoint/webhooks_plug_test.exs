defmodule Discord.Endpoint.WebhooksPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Discord.Endpoint.WebhooksPlug
  alias Discord.Webhooks.EventBuffer

  setup_all do
    start_supervised!({Discord.Webhooks, []})
    :ok
  end

  setup do
    EventBuffer.clear()

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    public_key_hex = Base.encode16(pub, case: :lower)
    state = WebhooksPlug.init(public_key: public_key_hex)

    %{public_key: public_key_hex, private_key: priv, state: state}
  end

  defp signed_post(body, %{private_key: priv}) do
    timestamp = Integer.to_string(System.system_time(:second))
    sig = :crypto.sign(:eddsa, :none, timestamp <> body, [priv, :ed25519])

    :post
    |> conn("/webhooks", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-signature-ed25519", Base.encode16(sig, case: :lower))
    |> put_req_header("x-signature-timestamp", timestamp)
  end

  test "PING (type 0) returns 204 with empty body", ctx do
    body = ~s({"version":1,"application_id":"1","type":0})

    conn = body |> signed_post(ctx) |> WebhooksPlug.call(ctx.state)

    assert conn.status == 204
    assert conn.resp_body == ""
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert EventBuffer.list() == []
  end

  test "valid event (type 1) returns 204 and pushes to buffer", ctx do
    body =
      ~s({"version":1,"application_id":"1","type":1,"event":{"type":"APPLICATION_AUTHORIZED","timestamp":"2024-10-18T14:42:53.064834","data":{"integration_type":1,"scopes":["applications.commands"],"user":{}}}})

    conn = body |> signed_post(ctx) |> WebhooksPlug.call(ctx.state)

    assert conn.status == 204
    assert conn.resp_body == ""

    assert [
             %{
               type: "APPLICATION_AUTHORIZED",
               received_at: <<_::binary>>,
               payload: %{"event" => %{"type" => "APPLICATION_AUTHORIZED"}}
             }
           ] = EventBuffer.list()
  end

  test "invalid signature returns 401 and does not push", ctx do
    body = ~s({"version":1,"application_id":"1","type":0})
    timestamp = "1730000000"
    bad_sig = String.duplicate("00", 64)

    conn =
      :post
      |> conn("/webhooks", body)
      |> put_req_header("x-signature-ed25519", bad_sig)
      |> put_req_header("x-signature-timestamp", timestamp)
      |> WebhooksPlug.call(ctx.state)

    assert conn.status == 401
    assert conn.resp_body == ~s({"error":"invalid_signature"})
    assert EventBuffer.list() == []
  end

  test "missing signature headers return 401", ctx do
    conn =
      :post
      |> conn("/webhooks", ~s({"type":0}))
      |> WebhooksPlug.call(ctx.state)

    assert conn.status == 401
    assert conn.resp_body == ~s({"error":"invalid_signature"})
  end

  test "non-POST returns 405", ctx do
    conn =
      :get
      |> conn("/webhooks")
      |> WebhooksPlug.call(ctx.state)

    assert conn.status == 405
    assert conn.resp_body == ~s({"error":"method_not_allowed"})
  end

  test "missing public key returns 503" do
    state = WebhooksPlug.init([])

    conn =
      :post
      |> conn("/webhooks", ~s({"type":0}))
      |> WebhooksPlug.call(state)

    assert conn.status == 503
    assert conn.resp_body == ~s({"error":"webhooks_not_configured"})
  end

  test "malformed JSON after valid signature returns 400", ctx do
    body = "{not json"

    conn = body |> signed_post(ctx) |> WebhooksPlug.call(ctx.state)

    assert conn.status == 400
    assert conn.resp_body == ~s({"error":"invalid_json"})
  end
end
