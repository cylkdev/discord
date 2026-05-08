defmodule Discord.Gateways.WebSocket do
  @moduledoc """
  Discord Gateway WebSocket client (v10, JSON encoding) implemented as a
  GenServer driving `:gun`.

  Lifecycle implemented per https://docs.discord.com/developers/events/gateway:

      connect → Hello (op 10) → Identify (op 2) → Heartbeat loop (op 1/11)
                                              ↘ Dispatch (op 0) → EventBuffer

  On Reconnect (op 7), Invalid Session (op 9, resumable), or socket close
  with a recoverable code, the GenServer reconnects to `resume_gateway_url`
  and sends Resume (op 6). On non-recoverable close codes (4004 auth failed,
  4010-4014 invalid shard / disallowed intents) the GenServer stops.

  Intents are hardcoded to `513` (GUILDS | GUILD_MESSAGES). MESSAGE_CONTENT
  is privileged and not requested.
  """

  use GenServer

  require Logger

  @host ~c"gateway.discord.gg"
  @port 443
  @path "/?v=10&encoding=json"
  @intents 513

  # Discord opcodes
  @op_dispatch 0
  @op_heartbeat 1
  @op_identify 2
  @op_resume 6
  @op_reconnect 7
  @op_invalid_session 9
  @op_hello 10
  @op_heartbeat_ack 11

  @nonrecoverable_close_codes [4004, 4010, 4011, 4012, 4013, 4014]

  ## Public API

  def via_tuple(name) do
    {:via, Registry, {Discord.Gateways.WebSocketRegistry, name}}
  end

  def start_link(name, token, opts) do
    GenServer.start_link(__MODULE__, {name, token, opts}, name: via_tuple(name))
  end

  def connected?(name) do
    case Discord.Gateways.WebSocketRegistry.lookup(name) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  def child_spec({name, token, opts}) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [name, token, opts]},
      type: :worker,
      restart: opts[:restart] || :transient,
      shutdown: opts[:shutdown] || 5_000
    }
  end

  ## GenServer

  @impl true
  def init({name, token, _opts}) do
    state = %{
      name: name,
      token: token,
      conn_pid: nil,
      stream_ref: nil,
      monitor_ref: nil,
      heartbeat_interval: nil,
      heartbeat_ref: nil,
      last_seq: nil,
      last_ack?: true,
      session_id: nil,
      resume_gateway_url: nil,
      status: :connecting
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: do_connect(state, :identify)

  defp do_connect(state, mode) do
    {host, port} =
      case state.resume_gateway_url do
        url when is_binary(url) and mode == :resume -> parse_url(url)
        _ -> {@host, @port}
      end

    case :gun.open(host, port, %{
           protocols: [:http],
           transport: :tls,
           tls_opts: [verify: :verify_none]
         }) do
      {:ok, conn_pid} ->
        await_up(state, mode, conn_pid)

      {:error, reason} ->
        Logger.error(
          "[discord #{inspect(state.name)}] gun open failed: #{inspect(reason)} (host=#{inspect(host)} port=#{port})"
        )

        schedule_reconnect()
        {:noreply, %{state | conn_pid: nil, stream_ref: nil, monitor_ref: nil, status: :reconnecting}}
    end
  end

  defp await_up(state, mode, conn_pid) do
    monitor_ref = Process.monitor(conn_pid)

    case :gun.await_up(conn_pid, 10_000) do
      {:ok, _protocol} ->
        stream_ref = :gun.ws_upgrade(conn_pid, @path)

        {:noreply,
         %{
           state
           | conn_pid: conn_pid,
             stream_ref: stream_ref,
             monitor_ref: monitor_ref,
             status: if(mode == :resume, do: :resuming, else: :connecting),
             last_ack?: true
         }}

      {:error, reason} ->
        Logger.error("[discord #{inspect(state.name)}] gun connection failed: #{inspect(reason)}")
        Process.demonitor(monitor_ref, [:flush])
        :gun.close(conn_pid)
        schedule_reconnect()

        {:noreply,
         %{state | conn_pid: nil, stream_ref: nil, monitor_ref: nil, status: :reconnecting}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.status == :ready, state}
  end

  @impl true
  def handle_info(
        {:gun_upgrade, conn_pid, stream_ref, ["websocket"], _headers},
        %{conn_pid: conn_pid, stream_ref: stream_ref} = state
      ) do
    Logger.info("[discord #{inspect(state.name)}] websocket upgraded")
    {:noreply, state}
  end

  def handle_info(
        {:gun_response, conn_pid, _ref, _is_fin, status, _headers},
        %{conn_pid: conn_pid} = state
      ) do
    Logger.error(
      "[discord #{inspect(state.name)}] websocket upgrade rejected: #{status} — stopping (no restart)"
    )

    close_gun(state)
    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn_pid, _ref, reason}, %{conn_pid: conn_pid} = state) do
    Logger.error("[discord #{inspect(state.name)}] gun error: #{inspect(reason)}")
    {:noreply, reconnect(state, recoverable_resume?(state))}
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, {:text, payload}},
        %{conn_pid: conn_pid, stream_ref: stream_ref} = state
      ) do
    case JSON.decode(payload) do
      {:ok, frame} ->
        handle_frame(frame, state)

      {:error, reason} ->
        Logger.error("[discord #{inspect(state.name)}] json decode failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, {:close, code, reason}},
        %{conn_pid: conn_pid} = state
      ) do
    Logger.warning(
      "[discord #{inspect(state.name)}] websocket closed: #{code} #{inspect(reason)}"
    )

    cond do
      code in @nonrecoverable_close_codes ->
        Logger.error(
          "[discord #{inspect(state.name)}] non-recoverable close #{code} — stopping (no restart)"
        )

        close_gun(state)
        {:stop, :normal, state}

      true ->
        {:noreply, reconnect(state, recoverable_resume?(state))}
    end
  end

  def handle_info({:gun_down, conn_pid, _proto, reason, _killed}, %{conn_pid: conn_pid} = state) do
    Logger.warning("[discord #{inspect(state.name)}] gun down: #{inspect(reason)}")
    {:noreply, reconnect(state, recoverable_resume?(state))}
  end

  def handle_info(
        {:DOWN, ref, :process, conn_pid, reason},
        %{monitor_ref: ref, conn_pid: conn_pid} = state
      ) do
    Logger.warning("[discord #{inspect(state.name)}] gun process down: #{inspect(reason)}")
    {:noreply, reconnect(%{state | conn_pid: nil, monitor_ref: nil}, recoverable_resume?(state))}
  end

  def handle_info(:heartbeat, state) do
    if state.last_ack? do
      send_frame(state, %{op: @op_heartbeat, d: state.last_seq})
      ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
      {:noreply, %{state | heartbeat_ref: ref, last_ack?: false}}
    else
      Logger.warning(
        "[discord #{inspect(state.name)}] heartbeat ack missed — reconnecting with resume"
      )

      {:noreply, reconnect(state, true)}
    end
  end

  def handle_info(:reconnect, state),
    do: do_connect(state, if(state.session_id, do: :resume, else: :identify))

  def handle_info(msg, state) do
    Logger.debug("[discord #{inspect(state.name)}] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Frame dispatch

  defp handle_frame(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}}, state) do
    Logger.info("[discord #{inspect(state.name)}] hello (heartbeat #{interval}ms)")
    jitter = trunc(interval * :rand.uniform())
    ref = Process.send_after(self(), :heartbeat, jitter)

    state = %{state | heartbeat_interval: interval, heartbeat_ref: ref, last_ack?: true}

    case state.status do
      :resuming -> send_resume(state)
      _ -> send_identify(state)
    end

    {:noreply, state}
  end

  defp handle_frame(%{"op" => @op_heartbeat_ack}, state) do
    {:noreply, %{state | last_ack?: true}}
  end

  defp handle_frame(%{"op" => @op_heartbeat}, state) do
    send_frame(state, %{op: @op_heartbeat, d: state.last_seq})
    {:noreply, state}
  end

  defp handle_frame(%{"op" => @op_reconnect}, state) do
    Logger.info("[discord #{inspect(state.name)}] reconnect requested")
    {:noreply, reconnect(state, true)}
  end

  defp handle_frame(%{"op" => @op_invalid_session, "d" => resumable?}, state) do
    Logger.warning("[discord #{inspect(state.name)}] invalid session (resumable=#{resumable?})")
    Process.sleep(1_000 + :rand.uniform(4_000))
    {:noreply, reconnect(state, resumable? == true)}
  end

  defp handle_frame(%{"op" => @op_dispatch, "t" => type, "s" => seq, "d" => data}, state) do
    state = %{state | last_seq: seq}

    state =
      case type do
        "READY" ->
          %{
            state
            | session_id: data["session_id"],
              resume_gateway_url: data["resume_gateway_url"],
              status: :ready
          }

        "RESUMED" ->
          %{state | status: :ready}

        _ ->
          state
      end

    Discord.Gateways.EventBuffer.push(%{
      type: type,
      seq: seq,
      received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    })

    {:noreply, state}
  end

  defp handle_frame(other, state) do
    Logger.debug("[discord #{inspect(state.name)}] unhandled frame: #{inspect(other)}")
    {:noreply, state}
  end

  ## Send helpers

  defp send_identify(state) do
    payload = %{
      op: @op_identify,
      d: %{
        token: state.token,
        intents: @intents,
        properties: %{os: "linux", browser: "discord", device: "discord"}
      }
    }

    send_frame(state, payload)
  end

  defp send_resume(state) do
    payload = %{
      op: @op_resume,
      d: %{
        token: state.token,
        session_id: state.session_id,
        seq: state.last_seq
      }
    }

    send_frame(state, payload)
  end

  defp send_frame(%{conn_pid: conn_pid, stream_ref: stream_ref}, payload)
       when is_pid(conn_pid) and not is_nil(stream_ref) do
    :gun.ws_send(conn_pid, stream_ref, {:text, JSON.encode!(payload)})
  end

  defp send_frame(_state, _payload), do: :ok

  ## Reconnect helpers

  defp reconnect(state, resume?) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    if state.conn_pid, do: :gun.close(state.conn_pid)

    state = %{
      state
      | conn_pid: nil,
        stream_ref: nil,
        monitor_ref: nil,
        heartbeat_ref: nil,
        status: :reconnecting,
        session_id: if(resume?, do: state.session_id, else: nil),
        resume_gateway_url: if(resume?, do: state.resume_gateway_url, else: nil)
    }

    schedule_reconnect()
    state
  end

  defp schedule_reconnect, do: Process.send_after(self(), :reconnect, 1_000)

  defp close_gun(%{conn_pid: nil}), do: :ok

  defp close_gun(%{conn_pid: conn_pid, monitor_ref: ref}) do
    if ref, do: Process.demonitor(ref, [:flush])
    :gun.close(conn_pid)
    :ok
  end

  defp recoverable_resume?(%{session_id: sid}) when is_binary(sid), do: true
  defp recoverable_resume?(_), do: false

  defp parse_url("wss://" <> rest), do: parse_host(rest)
  defp parse_url("ws://" <> rest), do: parse_host(rest)
  defp parse_url(_), do: {@host, @port}

  defp parse_host(rest) do
    host = rest |> String.split("/", parts: 2) |> hd() |> String.split(":", parts: 2) |> hd()
    {String.to_charlist(host), @port}
  end
end
