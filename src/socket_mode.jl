"""
Slack Socket Mode (push) event loop.

Replaces timer-driven history polling with a websocket: `apps.connections.open`
(app-level `xapp-` token) returns a short-lived `wss://` URL; Slack pushes
message events as envelopes. Each envelope is acked immediately (Slack's ack
deadline is ~3s; Claude dispatch takes minutes) and then routed into the same
dispatch paths as polling mode. The bot token and `chat.postMessage` reply path
are unchanged — Socket Mode is events-in only.

Delivery is at-least-once with gaps across disconnects, so the cursor machinery
(`last_ts`, per-thread `last_reply_ts`, `listen_last_ts`) is kept as a
reconciliation poll: `reconcile_messages!` runs on every (re)connect and every
`reconcile_interval_s`. The `claim_*!` cursor gates make socket dispatch,
reconciliation, and Slack redeliveries idempotent against each other.
"""

# Subtypes whose events carry a plain dispatchable message payload. Others
# (message_changed, message_deleted, channel_join, ...) have different shapes
# or semantics and are skipped — the reconciliation poll sees canonical
# history anyway.
const SOCKET_MESSAGE_SUBTYPES = ("", "thread_broadcast", "file_share")

"""
    classify_socket_event(event, config, tracked_threads) -> (route::Symbol, msg)

Pure routing decision for a Socket Mode message event. Routes:

- `:primary`       — top-level message in the monitored channel
- `:thread_reply`  — reply inside a tracked thread
- `:listen`        — top-level message in a configured listen channel
- `:ignore`        — everything else

Bot/self/empty filtering is NOT done here: the dispatcher applies
`should_process` after claiming the cursor, mirroring the poll paths (cursors
advance past bot messages too, which keeps reconciliation cheap).
"""
function classify_socket_event(event::Dict, config::SlackClawConfig, tracked_threads)
    get(event, "type", "") == "message" || return (:ignore, nothing)
    get(event, "subtype", "") in SOCKET_MESSAGE_SUBTYPES || return (:ignore, nothing)
    ts = get(event, "ts", "")
    isempty(ts) && return (:ignore, nothing)

    msg = SlackMessage(ts, get(event, "user", ""), get(event, "text", ""),
                       get(event, "thread_ts", ""))
    ch = get(event, "channel", "")

    if !isempty(msg.thread_ts) && msg.thread_ts != msg.ts
        msg.thread_ts in tracked_threads && return (:thread_reply, msg)
        return (:ignore, nothing)  # reply in a thread we don't track
    end
    ch == config.slack_channel_id && return (:primary, msg)
    ch in config.listen_channel_ids && return (:listen, msg)
    return (:ignore, nothing)  # bot is in the channel but it's not configured
end

"""Route one Socket Mode message event into the regular dispatch paths."""
function route_socket_event!(state::MonitorState, event::Dict)
    config = state.config
    route, msg = classify_socket_event(event, config, keys(state.threads))
    route == :ignore && return nothing

    if route == :primary
        claim_primary!(state, msg.ts) || return nothing
        save_state!(state)
        should_process(msg, config, event) || return nothing
        dispatch_command!(state, msg)

    elseif route == :thread_reply
        session = get(state.threads, msg.thread_ts, nothing)
        session === nothing && return nothing
        session.channel_id == get(event, "channel", "") || return nothing
        claim_thread_reply!(state, session, msg.ts) || return nothing
        save_state!(state)
        should_process(msg, config, event) || return nothing
        dispatch_thread_reply!(state, msg, session)

    elseif route == :listen
        ch = get(event, "channel", "")
        claim_listen!(state, ch, msg.ts) || return nothing
        save_state!(state)
        should_process(msg, config, event) || return nothing
        ch_name = get!(state.channel_names, ch) do
            try
                get(slack_conversations_info(config, ch), "name", ch)
            catch
                ch
            end
        end
        prefixed = SlackMessage(msg.ts, msg.user, "[from #$(ch_name)] $(msg.text)",
                                msg.thread_ts)
        dispatch_listen_command!(state, prefixed, ch_name)
    end
    return nothing
end

"""
Handle one websocket frame. Returns `:ok` to keep reading or `:reconnect` when
Slack asks for the connection to be refreshed.
"""
function handle_socket_frame!(state::MonitorState, ws, raw)
    data = try
        JSON.parse(String(raw))
    catch
        @warn "SlackClaw: unparseable socket frame"
        return :ok
    end
    data isa Dict || return :ok
    t = get(data, "type", "")

    if t == "hello"
        @info "SlackClaw: Socket Mode connected" num_connections=get(data, "num_connections", 1)
        return :ok

    elseif t == "disconnect"
        reason = get(data, "reason", "")
        @info "SlackClaw: socket disconnect frame" reason
        # "warning" is ~1min advance notice — keep serving until the actual refresh
        return reason == "warning" ? :ok : :reconnect

    else
        # Ack FIRST, before any dispatch work (3s deadline; unacked envelopes
        # get redelivered).
        envelope_id = get(data, "envelope_id", "")
        if !isempty(envelope_id)
            HTTP.WebSockets.send(ws, JSON.json(Dict("envelope_id" => envelope_id)))
        end
        if t == "events_api"
            retry_attempt = get(data, "retry_attempt", 0)
            retry_attempt isa Integer && retry_attempt > 0 &&
                @info "SlackClaw: redelivered envelope (cursor dedup applies)" retry_attempt
            event = get(get(data, "payload", Dict()), "event", Dict())
            event isa Dict && route_socket_event!(state, event)
        end
        return :ok
    end
end

"""Fire scheduled tasks/proactive checks and the periodic reconciliation poll."""
function socket_housekeeping!(state::MonitorState)
    config = state.config
    last_reconcile = time()
    while state.running
        try
            check_scheduled!(state)
            check_proactive!(state)
            if time() - last_reconcile >= config.reconcile_interval_s
                last_reconcile = time()
                reconcile_messages!(state)
            end
        catch e
            @error "SlackClaw housekeeping error" exception=(e, catch_backtrace())
        end
        for _ in 1:max(config.poll_interval_s, 1)
            state.running || break
            sleep(1)
        end
    end
end

"""
Socket Mode main loop: connect, read frames, reconnect with backoff.
Runs until `state.running` is false.
"""
function socket_loop!(state::MonitorState)
    config = state.config
    housekeeping = @async socket_housekeeping!(state)
    backoff = 1.0

    while state.running
        connected = false
        try
            url = slack_apps_connections_open(config)
            HTTP.WebSockets.open(url) do ws
                connected = true
                backoff = 1.0
                # Fill the gap from before/between connections
                @async try
                    reconcile_messages!(state)
                catch e
                    @error "SlackClaw reconcile error" exception=(e, catch_backtrace())
                end
                for raw in ws
                    state.running || break
                    handle_socket_frame!(state, ws, raw) == :reconnect && break
                end
            end
        catch e
            e isa InterruptException && rethrow()
            state.running || break
            @error "SlackClaw socket error" exception=(e, catch_backtrace())
        end
        state.running || break
        connected || (backoff = min(backoff * 2, 60.0))
        @info "SlackClaw: socket reconnecting in $(round(backoff; digits=1))s"
        sleep(backoff)
    end

    try
        wait(housekeeping)
    catch
    end
    return nothing
end
