defmodule Discord.Endpoint.Response do
  @moduledoc false

  alias Plug.Conn

  @logger_prefix "Discord.Endpoint.Response"

  def send_json(conn, status, payload) when is_map(payload) or is_list(payload) do
    send_json(conn, status, JSON.encode!(payload))
  end

  def send_json(conn, status, body) when is_binary(body) do
    Discord.Log.debug(@logger_prefix, "responding", status: status, size: byte_size(body))

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
  end
end
