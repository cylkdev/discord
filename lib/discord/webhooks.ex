defmodule Discord.Webhooks do
  @moduledoc """
  Receiver for Discord webhook events.

  Discord delivers a class of events as outgoing HTTPS POSTs (separate from
  the realtime Gateway). Examples include `APPLICATION_AUTHORIZED`,
  `ENTITLEMENT_CREATE`, and the SDK lobby/DM events. See
  https://docs.discord.com/developers/events/webhook-events for the full
  list and payload shapes.

  This supervisor owns the event buffer that `Discord.Endpoint.WebhooksPlug`
  pushes verified events into. It is started explicitly (not from
  `Discord.Application`) so callers can opt in — same pattern as
  `Discord.Gateways`.

  The Ed25519 public key for the Discord application is supplied as a plug
  option to `Discord.Endpoint.start_link/1` (`:public_key`); it is not held
  by this supervisor.

  iex> Discord.Webhooks.events()
  [%{type: "APPLICATION_AUTHORIZED", received_at: "...", payload: %{...}}, ...]
  """

  use Supervisor

  alias Discord.Webhooks.EventBuffer

  @logger_prefix "Discord.Webhooks"

  def start_link(opts \\ []) do
    Discord.Log.info(@logger_prefix, "starting")
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {EventBuffer, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Returns the buffered webhook events, newest-first."
  @spec events() :: [map]
  def events, do: EventBuffer.list()
end
