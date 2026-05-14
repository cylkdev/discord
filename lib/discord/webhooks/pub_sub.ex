defmodule Discord.Webhooks.PubSub do
  @moduledoc """
  In-process pubsub for verified Discord webhook events, backed by a
  duplicate-keys `Registry`.

  Observable behaviour:

    * Single global topic `:all` (webhooks aren't named per-connection).
    * Subscribers receive `{:webhook_event, event_map}` as a regular
      process message, where `event_map` is:

          %{
            type:        String.t(),
            received_at: String.t(),
            payload:     map()
          }

    * The library does not store events. Each subscriber decides what to
      keep and where.
    * `Registry` automatically removes a subscriber pid when it exits.

  Public-contract note: subscribers should depend only on the documented
  `{:webhook_event, %{...}}` tuple shape, not on Registry internals.
  """

  @registry __MODULE__
  @topic :all
  @logger_prefix "Discord.Webhooks.PubSub"

  @type event :: %{
          type: String.t(),
          received_at: String.t(),
          payload: map()
        }

  @doc """
  Returns a supervisor child spec for the underlying `Registry`.

  Inputs: `opts` (keyword) — passed through to `Registry.start_link/1`.
  Returns: a `Supervisor.child_spec/0`-shaped map. Contract: starts a
  duplicate-keys `Registry` named `Discord.Webhooks.PubSub`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Discord.Log.info(@logger_prefix, "pubsub starting")

    opts
    |> Keyword.put(:keys, :duplicate)
    |> Keyword.put(:name, @registry)
    |> Registry.start_link()
  end

  @doc """
  Subscribes the calling process to all verified webhook events.

  Returns `:ok`. Contract: after this call, every subsequent `broadcast/1`
  delivers `{:webhook_event, event}` to the calling process exactly once
  per call. Side effect: registers the calling pid under the single global
  topic.
  """
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _} = Registry.register(@registry, @topic, nil)
    :ok
  end

  @doc """
  Unsubscribes the calling process from webhook events.

  Returns `:ok`. Contract: removes the calling pid from the global topic.
  Idempotent.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Registry.unregister(@registry, @topic)
  end

  @doc """
  Broadcasts `event` to all webhook subscribers.

  Inputs: `event` (map). Returns `:ok`. Contract: every pid subscribed
  via `subscribe/0` receives exactly one `{:webhook_event, event}` message.
  Side effect: emits a debug log line for parity with the previous buffered
  push log.
  """
  @spec broadcast(event()) :: :ok
  def broadcast(event) when is_map(event) do
    Discord.Log.debug(@logger_prefix, "broadcast event",
      type: event[:type]
    )

    msg = {:webhook_event, event}

    Registry.dispatch(@registry, @topic, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, msg) end)
    end)

    :ok
  end
end
