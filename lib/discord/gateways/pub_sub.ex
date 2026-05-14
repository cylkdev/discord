defmodule Discord.Gateways.PubSub do
  @moduledoc """
  In-process pubsub for Discord Gateway dispatch events, backed by a
  duplicate-keys `Registry`.

  Observable behaviour:

    * Subscribers register against one of two topic shapes:
      - `{:all, connection_name}` — every dispatch for one connection.
      - `{:type, connection_name, event_type}` — one type for one connection.
    * `broadcast/2` dispatches to BOTH the `{:all, name}` topic AND the
      `{:type, name, event.type}` topic so each subscriber receives exactly
      one copy regardless of which topic they chose.
    * Connection names accepted as atoms or strings; normalized to strings
      on both subscribe and broadcast.
    * Subscribers receive `{:gateway_event, event_map}` as a regular process
      message. The `event_map` is the full dispatch event:

          %{
            connection: name :: String.t(),
            type:       String.t(),
            seq:        non_neg_integer() | nil,
            received_at: String.t(),
            data:       map()
          }

    * The library does not store events. Each subscriber decides what to
      keep and where.
    * `Registry` automatically removes a subscriber pid when it exits;
      callers do not need to call `unsubscribe/1,2` on exit.

  Public-contract note: subscribers should only rely on the documented
  `{:gateway_event, %{...}}` tuple shape — never on Registry internals.
  """

  @registry __MODULE__
  @logger_prefix "Discord.Gateways.PubSub"

  @type connection_name :: atom() | String.t()
  @type event_type :: String.t()
  @type event :: %{
          connection: String.t(),
          type: String.t(),
          seq: non_neg_integer() | nil,
          received_at: String.t(),
          data: map()
        }

  @doc """
  Returns a supervisor child spec that starts the underlying `Registry`.

  Inputs: `opts` (keyword) — passed through to `Registry.start_link/1`.
  Returns: a `Supervisor.child_spec/0`-shaped map. Contract: starts a
  duplicate-keys `Registry` named `Discord.Gateways.PubSub`.
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
  Subscribes the calling process to every dispatch event for `name`.

  Inputs: `name` — atom or string. Returns `:ok`. Contract: after this call,
  any subsequent `broadcast/2` for the same `name` delivers
  `{:gateway_event, event}` to the calling process exactly once per call.
  Side effect: registers the calling pid under topic `{:all, name_string}`.
  Preconditions: caller must be alive. Postconditions: caller appears in
  the registry for this topic until it exits or calls `unsubscribe/1`.
  """
  @spec subscribe(connection_name()) :: :ok
  def subscribe(name) do
    key = {:all, normalize(name)}
    {:ok, _} = Registry.register(@registry, key, nil)
    :ok
  end

  @doc """
  Subscribes the calling process to one event type for `name`.

  Inputs: `name` (atom/string), `type` (string). Returns `:ok`. Contract:
  after this call, a `broadcast/2` whose event has matching `type` delivers
  `{:gateway_event, event}` to the calling process; broadcasts with other
  types do not. Side effect: registers the calling pid under topic
  `{:type, name_string, type}`.
  """
  @spec subscribe(connection_name(), event_type()) :: :ok
  def subscribe(name, type) when is_binary(type) do
    key = {:type, normalize(name), type}
    {:ok, _} = Registry.register(@registry, key, nil)
    :ok
  end

  @doc """
  Unsubscribes the calling process from every-dispatch delivery for `name`.

  Inputs: `name`. Returns `:ok`. Contract: removes the calling pid from the
  `{:all, name}` topic. Idempotent — calling on a topic the caller is not
  registered to is allowed and still returns `:ok`.
  """
  @spec unsubscribe(connection_name()) :: :ok
  def unsubscribe(name) do
    Registry.unregister(@registry, {:all, normalize(name)})
  end

  @doc """
  Unsubscribes the calling process from typed delivery for `name`/`type`.

  Inputs: `name`, `type`. Returns `:ok`. Contract: removes the calling pid
  from the `{:type, name, type}` topic. Idempotent.
  """
  @spec unsubscribe(connection_name(), event_type()) :: :ok
  def unsubscribe(name, type) when is_binary(type) do
    Registry.unregister(@registry, {:type, normalize(name), type})
  end

  @doc """
  Broadcasts `event` to all subscribers of `name`.

  Inputs: `name` (atom/string), `event` (map containing at least a `:type`
  string). Returns `:ok`. Contract: every pid subscribed via `subscribe/1`
  for `name` AND every pid subscribed via `subscribe/2` for `{name, event.type}`
  receives exactly one `{:gateway_event, event}` message. Side effect:
  emits a debug log line for parity with the previous buffered-event log.
  """
  @spec broadcast(connection_name(), event()) :: :ok
  def broadcast(name, %{type: type} = event) when is_binary(type) do
    name_string = normalize(name)

    Discord.Log.debug(
      @logger_prefix,
      "broadcast event connection=#{inspect(name_string)} type=#{inspect(type)} seq=#{inspect(event[:seq])}"
    )

    dispatch_to(name_string, event, type)
    :ok
  end

  defp dispatch_to(name_string, event, type) do
    msg = {:gateway_event, event}

    Registry.dispatch(@registry, {:all, name_string}, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, msg) end)
    end)

    Registry.dispatch(@registry, {:type, name_string, type}, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, msg) end)
    end)
  end

  defp normalize(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize(name) when is_binary(name), do: name
end
