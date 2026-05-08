defmodule Discord.Endpoint.GatewayPlug do
  @moduledoc """
  REST endpoints for gateway state.

      GET /gateways/health  -> per-gateway connection status
      GET /gateways/events  -> list buffered dispatch events

  Health enumerates `Discord.Gateways.WebSocketRegistry` at request time,
  so the endpoint reports on whatever gateways happen to be running —
  no init-time configuration required.
  """

  @behaviour Plug

  alias Discord.Endpoint.Response
  alias Plug.Conn

  @health_path ["gateways", "health"]
  @events_path ["gateways", "events"]

  @impl true
  def init(_opts), do: %{}

  @impl true
  def call(%Conn{method: "GET", path_info: @health_path} = conn, _state) do
    Response.send_json(conn, 200, %{status: "ok", gateways: Discord.Gateways.list_connection_info()})
  end

  @impl true
  def call(%Conn{method: "GET", path_info: @events_path} = conn, _opts) do
    Response.send_json(conn, 200, %{events: Discord.Gateways.EventBuffer.list()})
  end

  @impl true
  def call(%Conn{path_info: @events_path} = conn, _opts) do
    Response.send_json(conn, 405, %{error: "method_not_allowed"})
  end

  def call(conn, _opts), do: Response.send_json(conn, 404, %{error: "not_found"})
end
