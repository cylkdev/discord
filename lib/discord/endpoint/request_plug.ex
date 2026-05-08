defmodule Discord.Endpoint.RequestPlug do
  @moduledoc """
  Entry-point plug for the Discord Gateway HTTP API.

  Dispatches to a per-resource plug based on the first segment of
  `conn.path_info`. Each sub-plug owns its own routing, methods, and
  response shapes:

      /gateways  -> Discord.Endpoint.GatewayPlug
      /webhooks  -> Discord.Endpoint.WebhooksPlug
      *          -> 404
  """

  @behaviour Plug

  alias Discord.Endpoint.{GatewayPlug, Response, WebhooksPlug}
  alias Plug.Conn

  @routes %{
    "gateways" => GatewayPlug,
    "webhooks" => WebhooksPlug
  }

  @impl true
  def init(opts) do
    Map.new(@routes, fn {prefix, plug} ->
      {prefix, {plug, plug.init(opts)}}
    end)
  end

  @impl true
  def call(%Conn{path_info: [prefix | _]} = conn, state) do
    case Map.fetch(state, prefix) do
      {:ok, {plug, plug_state}} -> plug.call(conn, plug_state)
      :error -> Response.send_json(conn, 404, %{error: "not_found"})
    end
  end

  def call(conn, _state), do: Response.send_json(conn, 404, %{error: "not_found"})
end
