defmodule Discord.Endpoint.HealthPlug do
  @moduledoc """
  REST endpoints for gateway state.

      GET /health  -> health check

  Health enumerates `Discord.Gateways.WebSocketRegistry` at request time,
  so the endpoint reports on whatever gateways happen to be running —
  no init-time configuration required.
  """

  @behaviour Plug

  alias Discord.Endpoint.Response
  alias Plug.Conn

  @logger_prefix "Discord.Endpoint.HealthPlug"

  @health_path ["health"]

  @impl true
  def init(_opts), do: %{}

  @impl true
  def call(%Conn{method: "GET", path_info: @health_path} = conn, _state) do
    info = Discord.Gateways.list_connection_info()
    Discord.Log.debug(@logger_prefix, "health request", gateway_count: length(info))
    Response.send_json(conn, 200, %{status: "ok", gateways: info})
  end

  def call(conn, _opts) do
    conn
  end
end
