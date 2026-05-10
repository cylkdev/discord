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

  The identify payload uses the normalized gateway intents supplied by
  `Discord.Gateways.connect/3`. The default comes from
  `Discord.Gateways.default_intents/0`.
  """

  use GenServer

  alias Discord.Gateways.EventBuffer

  @logger_prefix "Discord.Gateways.WebSocket"

  @host ~c"gateway.discord.gg"
  @port 443
  @path "/?v=10&encoding=json"
  @message_preview_limit 120

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
    case Discord.Gateways.WebSocketRegistry.lookup(normalize_registry_name(name)) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  def connection_info(name) do
    case Discord.Gateways.WebSocketRegistry.lookup(normalize_registry_name(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :connection_info)
    end
  end

  def token(name) do
    case Discord.Gateways.WebSocketRegistry.lookup(normalize_registry_name(name)) do
      nil -> {:error, :not_connected}
      pid -> GenServer.call(pid, :token)
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
  def init({name, token, opts}) do
    Discord.Log.debug(@logger_prefix, "init gateway websocket registry_name=#{inspect(name)}")

    public_name = Keyword.get(opts, :public_name, name)
    intents = Keyword.fetch!(opts, :intents)

    state = %{
      registry_name: name,
      name: name,
      public_name: public_name,
      token: token,
      intents: intents,
      intent_value: intents_to_value(intents),
      conn_pid: nil,
      stream_ref: nil,
      monitor_ref: nil,
      heartbeat_interval: nil,
      heartbeat_ref: nil,
      last_seq: nil,
      last_ack?: true,
      session_id: nil,
      resume_gateway_url: nil,
      status: :connecting,
      bot_user_id: nil,
      bot_username: nil
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

    Discord.Log.debug(
      @logger_prefix,
      "opening TLS connection to Discord Gateway name=#{inspect(state.public_name)} host=#{inspect(host)} port=#{port} mode=#{inspect(mode)}"
    )

    case :gun.open(host, port, %{
           protocols: [:http],
           transport: :tls,
           tls_opts: [verify: :verify_none]
         }) do
      {:ok, conn_pid} ->
        await_up(state, mode, conn_pid)

      {:error, reason} ->
        Discord.Log.error(
          @logger_prefix,
          "gun open failed name=#{inspect(state.public_name)} host=#{inspect(host)} port=#{port} reason=#{inspect(reason)}"
        )

        schedule_reconnect()

        {:noreply,
         %{state | conn_pid: nil, stream_ref: nil, monitor_ref: nil, status: :reconnecting}}
    end
  end

  defp await_up(state, mode, conn_pid) do
    monitor_ref = Process.monitor(conn_pid)

    case :gun.await_up(conn_pid, 10_000) do
      {:ok, _protocol} ->
        Discord.Log.debug(
          @logger_prefix,
          "TCP/TLS connection established, requesting websocket upgrade name=#{inspect(state.public_name)} mode=#{inspect(mode)} path=#{@path}"
        )

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
        Discord.Log.error(
          @logger_prefix,
          "connection failed before websocket upgrade name=#{inspect(state.public_name)} reason=#{inspect(reason)}"
        )

        Process.demonitor(monitor_ref, [:flush])
        :gun.close(conn_pid)
        schedule_reconnect()

        {:noreply,
         %{state | conn_pid: nil, stream_ref: nil, monitor_ref: nil, status: :reconnecting}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    Discord.Log.debug(
      @logger_prefix,
      "connected? query name=#{inspect(state.public_name)} status=#{inspect(state.status)}"
    )

    {:reply, state.status == :ready, state}
  end

  def handle_call(:connection_info, _from, state) do
    info = %{
      name: state.public_name,
      connected: state.status == :ready,
      status: state.status,
      bot_user_id: state.bot_user_id,
      bot_username: state.bot_username,
      intents: state.intents,
      session_id: state.session_id,
      resume_gateway_url: state.resume_gateway_url,
      event_count: EventBuffer.count(state.registry_name)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:token, _from, state) do
    {:reply, {:ok, state.token}, state}
  end

  @impl true
  def handle_info(
        {:gun_upgrade, conn_pid, stream_ref, ["websocket"], _headers},
        %{conn_pid: conn_pid, stream_ref: stream_ref} = state
      ) do
    Discord.Log.info(
      @logger_prefix,
      "websocket upgraded name=#{inspect(state.public_name)} status=#{inspect(state.status)}"
    )

    {:noreply, state}
  end

  def handle_info(
        {:gun_response, conn_pid, _ref, _is_fin, status, _headers},
        %{conn_pid: conn_pid} = state
      ) do
    Discord.Log.error(
      @logger_prefix,
      "websocket upgrade rejected by Discord name=#{inspect(state.public_name)} http_status=#{status}"
    )

    close_gun(state)
    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn_pid, _ref, reason}, %{conn_pid: conn_pid} = state) do
    Discord.Log.error(
      @logger_prefix,
      "transport error from gun name=#{inspect(state.public_name)} reason=#{inspect(reason)}"
    )

    {:noreply, reconnect(state, recoverable_resume?(state))}
  end

  def handle_info(
        {:gun_ws, conn_pid, stream_ref, {:text, payload}},
        %{conn_pid: conn_pid, stream_ref: stream_ref} = state
      ) do
    case JSON.decode(payload) do
      {:ok, frame} ->
        log_received_frame(state, frame, payload)
        handle_frame(frame, state)

      {:error, reason} ->
        Discord.Log.error(
          @logger_prefix,
          "failed to decode websocket payload as JSON name=#{inspect(state.public_name)} reason=#{inspect(reason)} payload_preview=#{inspect(truncate_text(payload, @message_preview_limit))}"
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:gun_ws, conn_pid, _stream_ref, {:close, code, reason}},
        %{conn_pid: conn_pid} = state
      ) do
    Discord.Log.warning(
      @logger_prefix,
      "websocket closed by Discord name=#{inspect(state.public_name)} code=#{code} code_name=#{inspect(close_code_name(code))} recoverable=#{code not in @nonrecoverable_close_codes} reason=#{inspect(normalize_close_reason(reason))}"
    )

    cond do
      code in @nonrecoverable_close_codes ->
        Discord.Log.error(
          @logger_prefix,
          "Discord rejected the session; stopping without reconnect name=#{inspect(state.public_name)} code=#{code} code_name=#{inspect(close_code_name(code))}"
        )

        close_gun(state)
        {:stop, :normal, state}

      true ->
        {:noreply, reconnect(state, recoverable_resume?(state))}
    end
  end

  def handle_info({:gun_down, conn_pid, _proto, reason, _killed}, %{conn_pid: conn_pid} = state) do
    Discord.Log.warning(
      @logger_prefix,
      "transport connection went down name=#{inspect(state.public_name)} reason=#{inspect(reason)}"
    )

    {:noreply, reconnect(state, recoverable_resume?(state))}
  end

  def handle_info(
        {:DOWN, ref, :process, conn_pid, reason},
        %{monitor_ref: ref, conn_pid: conn_pid} = state
      ) do
    Discord.Log.warning(
      @logger_prefix,
      "transport process exited name=#{inspect(state.public_name)} reason=#{inspect(reason)}"
    )

    {:noreply, reconnect(%{state | conn_pid: nil, monitor_ref: nil}, recoverable_resume?(state))}
  end

  def handle_info(:heartbeat, state) do
    if state.last_ack? do
      Discord.Log.debug(
        @logger_prefix,
        "sending heartbeat name=#{inspect(state.public_name)} seq=#{inspect(state.last_seq)}"
      )

      send_frame(state, %{op: @op_heartbeat, d: state.last_seq})
      ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
      {:noreply, %{state | heartbeat_ref: ref, last_ack?: false}}
    else
      Discord.Log.warning(
        @logger_prefix,
        "missed heartbeat ack; reconnecting with resume name=#{inspect(state.public_name)} last_seq=#{inspect(state.last_seq)}"
      )

      {:noreply, reconnect(state, true)}
    end
  end

  def handle_info(:reconnect, state),
    do: do_connect(state, if(state.session_id, do: :resume, else: :identify))

  def handle_info(msg, state) do
    Discord.Log.debug(
      @logger_prefix,
      "unhandled process message name=#{inspect(state.public_name)} msg=#{inspect(msg)}"
    )

    {:noreply, state}
  end

  ## Frame dispatch

  defp handle_frame(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}}, state) do
    jitter = trunc(interval * :rand.uniform())
    ref = Process.send_after(self(), :heartbeat, jitter)

    Discord.Log.info(
      @logger_prefix,
      "received HELLO and scheduled first heartbeat name=#{inspect(state.public_name)} heartbeat_interval_ms=#{interval} first_heartbeat_in_ms=#{jitter}"
    )

    state = %{state | heartbeat_interval: interval, heartbeat_ref: ref, last_ack?: true}

    case state.status do
      :resuming -> send_resume(state)
      _ -> send_identify(state)
    end

    {:noreply, state}
  end

  defp handle_frame(%{"op" => @op_heartbeat_ack}, state) do
    Discord.Log.debug(
      @logger_prefix,
      "received heartbeat ack name=#{inspect(state.public_name)} seq=#{inspect(state.last_seq)}"
    )

    {:noreply, %{state | last_ack?: true}}
  end

  defp handle_frame(%{"op" => @op_heartbeat}, state) do
    Discord.Log.debug(
      @logger_prefix,
      "received server heartbeat request name=#{inspect(state.public_name)} seq=#{inspect(state.last_seq)}"
    )

    send_frame(state, %{op: @op_heartbeat, d: state.last_seq})
    {:noreply, state}
  end

  defp handle_frame(%{"op" => @op_reconnect}, state) do
    Discord.Log.info(
      @logger_prefix,
      "Discord requested reconnect name=#{inspect(state.public_name)} session_id=#{inspect(state.session_id)} last_seq=#{inspect(state.last_seq)}"
    )

    {:noreply, reconnect(state, true)}
  end

  defp handle_frame(%{"op" => @op_invalid_session, "d" => resumable?}, state) do
    Discord.Log.warning(
      @logger_prefix,
      "received invalid session name=#{inspect(state.public_name)} resumable=#{inspect(resumable?)}"
    )

    Process.sleep(1_000 + :rand.uniform(4_000))
    {:noreply, reconnect(state, resumable? == true)}
  end

  defp handle_frame(%{"op" => @op_dispatch, "t" => type, "s" => seq, "d" => data}, state) do
    state = %{state | last_seq: seq}

    state =
      case type do
        "READY" ->
          Discord.Log.info(
            @logger_prefix,
            "received READY; gateway session is now authenticated name=#{inspect(state.public_name)} session_id=#{inspect(data["session_id"])} bot_user_id=#{inspect(get_in(data, ["user", "id"]))} bot_username=#{inspect(get_in(data, ["user", "username"]))} guild_count=#{length(data["guilds"] || [])} resume_gateway_url=#{inspect(data["resume_gateway_url"])}"
          )

          %{
            state
            | session_id: data["session_id"],
              resume_gateway_url: data["resume_gateway_url"],
              status: :ready,
              bot_user_id: get_in(data, ["user", "id"]),
              bot_username: get_in(data, ["user", "username"])
          }

        "RESUMED" ->
          Discord.Log.info(
            @logger_prefix,
            "received RESUMED; session restored name=#{inspect(state.public_name)} session_id=#{inspect(state.session_id)} last_seq=#{inspect(seq)}"
          )

          %{state | status: :ready}

        _ ->
          state
      end

    EventBuffer.push(state.registry_name, %{
      connection: state.public_name,
      type: type,
      seq: seq,
      received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data
    })

    {:noreply, state}
  end

  defp handle_frame(other, state) do
    Discord.Log.debug(
      @logger_prefix,
      "received unhandled gateway frame name=#{inspect(state.public_name)} frame=#{inspect(other)}"
    )

    {:noreply, state}
  end

  ## Send helpers

  defp send_identify(state) do
    Discord.Log.debug(
      @logger_prefix,
      "sending IDENTIFY name=#{inspect(state.public_name)} intents=#{inspect(state.intents)} intent_value=#{state.intent_value} message_content_requested=#{:message_content in state.intents}"
    )

    payload = %{
      op: @op_identify,
      d: %{
        token: state.token,
        intents: state.intent_value,
        properties: %{os: "linux", browser: "discord", device: "discord"}
      }
    }

    send_frame(state, payload)
  end

  defp send_resume(state) do
    Discord.Log.debug(
      @logger_prefix,
      "sending RESUME name=#{inspect(state.public_name)} session_id=#{inspect(state.session_id)} seq=#{inspect(state.last_seq)}"
    )

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

  defp send_frame(state, payload) do
    Discord.Log.warning(
      @logger_prefix,
      "dropping outbound frame because no websocket is active name=#{inspect(state.public_name)} op=#{inspect(payload[:op])}"
    )

    :ok
  end

  ## Reconnect helpers

  defp reconnect(state, resume?) do
    Discord.Log.info(
      @logger_prefix,
      "reconnecting gateway session name=#{inspect(state.public_name)} resume=#{resume?} last_seq=#{inspect(state.last_seq)} session_id=#{inspect(if(resume?, do: state.session_id, else: nil))}"
    )

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

  defp schedule_reconnect do
    Discord.Log.debug(@logger_prefix, "scheduled reconnect attempt delay_ms=1000")
    Process.send_after(self(), :reconnect, 1_000)
  end

  defp log_received_frame(
         state,
         %{"op" => @op_dispatch, "t" => type, "s" => seq, "d" => data},
         payload
       ) do
    Discord.Log.debug(
      @logger_prefix,
      "received dispatch frame name=#{inspect(state.public_name)} op=#{@op_dispatch} type=#{inspect(type)} seq=#{inspect(seq)} payload_bytes=#{byte_size(payload)} summary=#{inspect(summarize_dispatch(type, data), pretty: true, limit: 50, printable_limit: 1500)}"
    )
  end

  defp log_received_frame(state, %{"op" => op} = frame, payload) do
    Discord.Log.debug(
      @logger_prefix,
      "received gateway control frame name=#{inspect(state.public_name)} op=#{inspect(op)} payload_bytes=#{byte_size(payload)} frame=#{inspect(frame, pretty: true, limit: 50, printable_limit: 1500)}"
    )
  end

  defp summarize_dispatch("READY", data) do
    %{
      bot_user_id: get_in(data, ["user", "id"]),
      bot_username: get_in(data, ["user", "username"]),
      guild_count: length(data["guilds"] || []),
      session_id: data["session_id"]
    }
  end

  defp summarize_dispatch("MESSAGE_CREATE", data) do
    %{
      message_id: data["id"],
      channel_id: data["channel_id"],
      guild_id: data["guild_id"],
      author_id: get_in(data, ["author", "id"]),
      author_username: get_in(data, ["author", "username"]),
      content: truncate_text(data["content"], @message_preview_limit),
      content_present: present_string?(data["content"]),
      mention_count: length(data["mentions"] || []),
      attachment_count: length(data["attachments"] || [])
    }
  end

  defp summarize_dispatch("MESSAGE_UPDATE", data) do
    %{
      message_id: data["id"],
      channel_id: data["channel_id"],
      guild_id: data["guild_id"],
      content: truncate_text(data["content"], @message_preview_limit),
      content_present: present_string?(data["content"])
    }
  end

  defp summarize_dispatch("MESSAGE_DELETE", data) do
    %{
      message_id: data["id"],
      channel_id: data["channel_id"],
      guild_id: data["guild_id"]
    }
  end

  defp summarize_dispatch("MESSAGE_DELETE_BULK", data) do
    %{
      channel_id: data["channel_id"],
      guild_id: data["guild_id"],
      message_count: length(data["ids"] || []),
      message_ids_preview: Enum.take(data["ids"] || [], 5)
    }
  end

  defp summarize_dispatch(type, data) when is_map(data) do
    %{
      type: type,
      keys: data |> Map.keys() |> Enum.sort() |> Enum.take(12),
      id: data["id"],
      channel_id: data["channel_id"],
      guild_id: data["guild_id"]
    }
  end

  defp summarize_dispatch(type, data) do
    %{type: type, data: data}
  end

  defp truncate_text(value, _limit) when value in [nil, ""], do: value

  defp truncate_text(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "..."
  end

  defp truncate_text(value, _limit), do: value

  defp present_string?(value) when is_binary(value), do: value != ""
  defp present_string?(_), do: false

  defp normalize_close_reason(reason) when is_binary(reason), do: reason
  defp normalize_close_reason(reason) when is_list(reason), do: to_string(reason)
  defp normalize_close_reason(reason), do: inspect(reason)

  defp close_code_name(4_000), do: "unknown error"
  defp close_code_name(4_001), do: "unknown opcode"
  defp close_code_name(4_002), do: "decode error"
  defp close_code_name(4_003), do: "not authenticated"
  defp close_code_name(4_004), do: "authentication failed (invalid token)"
  defp close_code_name(4_005), do: "already authenticated"
  defp close_code_name(4_007), do: "invalid sequence"
  defp close_code_name(4_008), do: "rate limited"
  defp close_code_name(4_009), do: "session timed out"
  defp close_code_name(4_010), do: "invalid shard"
  defp close_code_name(4_011), do: "sharding required"
  defp close_code_name(4_012), do: "invalid api version"
  defp close_code_name(4_013), do: "invalid intent(s)"
  defp close_code_name(4_014), do: "disallowed intent(s)"
  defp close_code_name(other), do: "unknown close code #{other}"

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

  defp intents_to_value(intents) do
    Enum.reduce(intents, 0, fn
      :guilds, acc -> acc + 1
      :guild_messages, acc -> acc + 512
      :message_content, acc -> acc + 32_768
    end)
  end

  defp normalize_registry_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_registry_name(name) when is_binary(name), do: name
end
