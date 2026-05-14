defmodule Discord.Webhooks do
  @moduledoc """
  Receiver for Discord webhook events.

  Discord delivers a class of events as outgoing HTTPS POSTs (separate from
  the realtime Gateway). Examples include `APPLICATION_AUTHORIZED`,
  `ENTITLEMENT_CREATE`, and the SDK lobby/DM events. See
  https://docs.discord.com/developers/events/webhook-events for the full
  list and payload shapes.

  This supervisor owns the pubsub that `Discord.Endpoint.WebhooksPlug`
  broadcasts verified events over. It is started explicitly (not from
  `Discord.Application`) so callers can opt in — same pattern as
  `Discord.Gateways`.

  The Ed25519 public key for the Discord application is supplied as a plug
  option to `Discord.Endpoint.start_link/1` (`:public_key`); it is not held
  by this supervisor.

  Subscribe to receive verified webhook events as process messages:

      Discord.Webhooks.subscribe()
      # receive: {:webhook_event, %{type: "APPLICATION_AUTHORIZED", ...}}
  """

  use Supervisor

  alias Discord.Webhooks.PubSub

  @logger_prefix "Discord.Webhooks"

  def start_link(opts \\ []) do
    Discord.Log.info(@logger_prefix, "starting")
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {PubSub, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Subscribes the calling process to verified webhook events. Subscribers
  receive `{:webhook_event, event_map}` messages.

  Returns `:ok`. The subscription is auto-released when the calling process
  exits.
  """
  @spec subscribe() :: :ok
  def subscribe, do: PubSub.subscribe()

  @doc """
  Unsubscribes the calling process from webhook events.

  Returns `:ok`. Idempotent.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe, do: PubSub.unsubscribe()
end
