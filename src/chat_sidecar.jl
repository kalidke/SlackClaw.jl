"""Connect using the callback-form WebSockets API shared by HTTP 1.x and 2.x."""
function default_socket_connect(url, f)
    return HTTP.WebSockets.open(f, url; suppress_close_error=true)
end

"""Iterate complete messages on HTTP 1.x/2.x sockets; fakes may specialize this."""
socket_frames(ws) = ws

"""Send an acknowledgement; fake sockets may specialize this."""
socket_send(ws, text) = HTTP.WebSockets.send(ws, text)

"""Abort the transport without another WebSocket close handshake."""
function socket_forceclose(ws::HTTP.WebSockets.WebSocket)
    # Both versions' callback-form open must see a fully retired socket when
    # our callback returns, or its finally block starts another unbounded close.
    ws.readclosed = true
    ws.writeclosed = true
    if CHAT_HTTP_V2
        try
            ws.close_transport!()
        finally
            isopen(ws.readchannel) && close(ws.readchannel)
        end
    else
        close(ws.io)
    end
    return nothing
end

"""Write one bounded diagnostic using only a fixed event name and exception type."""
function chat_child_log(event::Symbol, exception=nothing; io::IO=chat_child_log_io())
    detail = exception === nothing ? "" : " $(nameof(typeof(exception)))"
    println(io, chat_bounded_text("SlackClaw chat: $event$detail", 511))
    flush(io)
end

"""Task-local logger that never prints third-party messages or exception contents."""
struct ChatChildLogger <: Base.CoreLogging.AbstractLogger
    io::IO
end

"""Use the entry point's diagnostic stream for direct diagnostics as well as logs."""
function chat_child_log_io()
    logger = Base.CoreLogging.current_logger()
    return logger isa ChatChildLogger ? logger.io : stderr
end

"""Identify HTTP and its nested modules without inspecting any log contents."""
function chat_child_http_module(mod)
    mod isa Module || return false
    while true
        (mod === HTTP || nameof(mod) == :HTTP) && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
end

"""Accept warning and error diagnostics only."""
Base.CoreLogging.min_enabled_level(::ChatChildLogger) = Base.CoreLogging.Warn

"""Filter log records without inspecting their untrusted contents."""
Base.CoreLogging.shouldlog(::ChatChildLogger, level, mod, group, id) =
    level >= Base.CoreLogging.Warn && !chat_child_http_module(mod)

"""Do not let the logging machinery dump a failed log record."""
Base.CoreLogging.catch_exceptions(::ChatChildLogger) = false

"""Replace library diagnostics with a fixed, bounded line."""
function Base.CoreLogging.handle_message(logger::ChatChildLogger, level, message,
                                        mod, group, id, file, line; kwargs...)
    Base.CoreLogging.shouldlog(logger, level, mod, group, id) || return nothing
    exception = get(kwargs, :exception, nothing)
    exception isa Tuple && !isempty(exception) && (exception = first(exception))
    chat_child_log(:library_diagnostic, exception; io=logger.io)
end

"""One workspace's socket and single FIFO consumer; credentials live in `workspace`."""
mutable struct ChatChildWorkspace
    workspace::ChatWorkspace
    queue::Channel{AbstractDict}
    capacity::Int
    overflowing::Bool
    socket::Any
    close_task::Union{Task,Nothing}
    retry_timer::Union{Timer,Nothing}
    connections::Int
    authenticated::Bool
    app_id::Union{String,Nothing}
    duplicate_app::Bool
end

"""Hide sockets, their private URLs and queued Slack data from display."""
Base.show(io::IO, ::ChatChildWorkspace) = print(io, "ChatChildWorkspace([private])")

"""A response race and cooperative cancellation flag retained until its worker exits."""
mutable struct ChatChildRequest
    id::Integer
    op::String
    replied::Bool
    cancelled::Bool
    timer::Union{Timer,Nothing}
    worker::Union{Task,Nothing}
    deadline_at::Float64
end

"""Child-owned admission and response state, shared only by cooperative tasks."""
mutable struct ChatChild
    input::IO
    output::IO
    write_lock::ReentrantLock
    options::NamedTuple
    workspaces::Dict{String,ChatChildWorkspace}
    secrets::Vector{String}
    configured::Bool
    stopping::Bool
    output_failed::Bool
    active::Int
    transfers::Int
    awaiting::Int
    settled::Base.Condition
    inflight::Set{Integer}
    requests::Vector{ChatChildRequest}
end

"""Unwind a failed frame write without retaining or displaying its contents."""
struct ChatChildOutputError <: Exception end

"""Never display credentials, transports, output buffers or pending request data."""
Base.show(io::IO, ::ChatChild) = print(io, "ChatChild([private])")

"""Refuse new transport calls after cancellation, sharing identity and name caches."""
function chat_child_cancellable_workspace(ws::ChatWorkspace, cancelled::Function)
    transport = function(args...; kwargs...)
        cancelled() && throw(ChatError(:timeout, "request cancelled"))
        return ws.transport(args...; kwargs...)
    end
    return ChatWorkspace(ws.id, ws.bot_token, ws.app_token, ws.channels, ws.posting_form,
                         transport, ws.bot_user_id, ws.bot_id, ws.names, ws.lock)
end

"""Whether an operation must always report its mutation outcome on failure."""
chat_child_mutation(op) = op in ("post", "file.upload")

"""Use only safe operation names in envelopes, even for malformed requests."""
function chat_child_op(value)
    return value isa AbstractString && ncodeunits(value) <= 64 &&
        occursin(r"\A[a-z][a-z0-9_.]*\z", value) ? String(value) : ""
end

"""Encode one whole frame, redacting exact configured credentials as a final guard."""
function chat_child_encode(child::ChatChild, frame)
    line = JSON.json(frame)
    for secret in child.secrets
        encoded = JSON.json(secret)
        line = replace(line, encoded[2:prevind(encoded, lastindex(encoded))] => "[redacted]")
    end
    return line
end

"""Serialize and flush a whole bounded frame under the sole stdout lock."""
function chat_child_write(child::ChatChild, frame::AbstractDict)
    line = chat_child_encode(child, frame)
    if ncodeunits(line) > child.options.max_line
        if get(frame, "kind", "") == "res"
            op = frame["op"]
            old = frame["payload"]
            outcome = chat_child_mutation(op) ?
                (get(old, "outcome", "") == "refused" ? :refused : :unknown) : :none
            frame = Dict{String,Any}("v" => 1, "id" => frame["id"], "kind" => "res", "op" => op,
                "payload" => chat_error_payload(ChatError(:too_large, "response exceeds line limit", nothing, outcome)))
            line = chat_child_encode(child, frame)
        end
        if ncodeunits(line) > child.options.max_line
            chat_child_log(:output_too_large)
            return nothing
        end
    end
    lock(child.write_lock) do
        child.output_failed && throw(ChatChildOutputError())
        try
            write(child.output, line, '\n')
            flush(child.output)
        catch e
            child.output_failed = true
            chat_child_begin_shutdown(child)
            chat_child_log(:output_failed, e)
            # Wake a protocol reader waiting for the daemon's next request.
            close(child.input)
            throw(ChatChildOutputError())
        end
    end
    return nothing
end

"""Write a response without retaining the request payload."""
function chat_child_reply(child::ChatChild, id::Integer, op::String, payload)
    chat_child_write(child, Dict{String,Any}("v" => 1, "id" => id, "kind" => "res", "op" => op,
                                           "payload" => payload))
end

"""Write an event unless shutdown has begun."""
function chat_child_event(child::ChatChild, op::String, payload)
    child.stopping || chat_child_write(child,
        Dict{String,Any}("v" => 1, "kind" => "evt", "op" => op, "payload" => payload))
end

"""Detach protocol output from the socket reader, observing task failures safely."""
function chat_child_emit(child::ChatChild, op::String, payload)
    @async try
        chat_child_event(child, op, payload)
    catch e
        child.output_failed || chat_child_log(:event_output_failed, e)
    end
    return nothing
end

"""Report socket state from another task so stdout never delays socket acks."""
function chat_child_status(child::ChatChild, runtime::ChatChildWorkspace, state::String; error=nothing)
    payload = Dict{String,Any}("workspace" => runtime.workspace.id, "state" => state)
    if error !== nothing
        payload["code"] = String(error.code)
        # Status explanations are fixed locally, never derived from Slack response text.
        payload["detail"] = "Slack connection unavailable"
        error.retry_after_s === nothing || (payload["retry_after_s"] = error.retry_after_s)
    end
    chat_child_emit(child, "status", payload)
end

"""Read through a newline with bounded storage; discard an oversized line in full."""
function chat_child_readline(input::IO, max_line::Integer)
    bytes = UInt8[]
    oversized = false
    while !eof(input)
        byte = read(input, UInt8)
        byte == 0x0a && return (oversized ? :oversized : :line, bytes)
        if length(bytes) < max_line
            push!(bytes, byte)
        else
            oversized = true
        end
    end
    return (oversized ? :oversized : isempty(bytes) ? :eof : :line, bytes)
end

"""Validate the complete configure payload before making any workspace visible."""
function chat_child_configure(child::ChatChild, payload::AbstractDict, transport)
    child.configured && throw(ChatError(:bad_request, "already configured"))
    entries = get(payload, "workspaces", nothing)
    entries isa AbstractVector || throw(ChatError(:bad_request, "invalid workspaces"))
    workspaces = Dict{String,ChatChildWorkspace}()
    apps = Set{String}()
    secrets = String[]
    for entry in entries
        entry isa AbstractDict || throw(ChatError(:bad_request, "invalid workspace"))
        id = chat_validate(get(entry, "id", nothing), "workspace")
        haskey(workspaces, id) && throw(ChatError(:bad_request, "duplicate workspace"))
        bot, app = get(entry, "bot_token", nothing), get(entry, "app_token", nothing)
        for (token, prefix) in ((bot, "xoxb-"), (app, "xapp-"))
            token isa AbstractString && startswith(token, prefix) && ncodeunits(token) <= 4096 &&
                ncodeunits(token) > ncodeunits(prefix) && !any(isspace, token) ||
                throw(ChatError(:bad_request, "invalid credentials"))
        end
        app in apps && throw(ChatError(:bad_request, "duplicate workspace app"))
        form = get(entry, "posting_form", nothing)
        form in ("custom", "prefix") || throw(ChatError(:bad_request, "invalid posting form"))
        channels = get(entry, "channels", nothing)
        channels isa AbstractVector || throw(ChatError(:bad_request, "invalid channels"))
        ws = ChatWorkspace(; id, bot_token=bot, app_token=app, channels,
                           posting_form=Symbol(form), transport)
        ws = chat_child_cancellable_workspace(ws, () -> child.stopping)
        length(unique(ws.channels)) == length(ws.channels) ||
            throw(ChatError(:bad_request, "duplicate channel"))
        workspaces[id] = ChatChildWorkspace(ws, Channel{AbstractDict}(child.options.queue_size),
            child.options.queue_size, false, nothing, nothing, nothing, 0, false, nothing, false)
        push!(apps, String(app))
        append!(secrets, (String(bot), String(app)))
    end
    child.workspaces = workspaces
    child.secrets = secrets
    child.configured = true
    return nothing
end

"""Open Socket Mode once with the app token, mapping failures without response dumps."""
function chat_child_socket_url(ws::ChatWorkspace; timeout_s::Real=20)
    response = try
        ws.transport("POST", "$SLACK_API_BASE/apps.connections.open",
            Pair{String,String}["Authorization" => "Bearer $(ws.app_token)"];
            body=UInt8[], timeout_s)
    catch e
        throw(chat_exception(e))
    end
    status = response.status
    status == 429 && throw(ChatError(:rate_limited, "Slack rate limited", chat_retry_after(response.headers)))
    status == 401 && throw(ChatError(:unauthorized, "Slack authentication rejected"))
    status == 403 && throw(ChatError(:forbidden, "Slack connection forbidden"))
    status >= 500 && throw(ChatError(:unavailable, "Slack connection unavailable"))
    200 <= status < 300 || throw(ChatError(:bad_request, "Slack connection rejected"))
    data = try
        JSON.parse(String(copy(response.body)))
    catch
        throw(ChatError(:io_error, "invalid Slack connection response"))
    end
    data isa AbstractDict || throw(ChatError(:io_error, "invalid Slack connection response"))
    if get(data, "ok", nothing) !== true
        error = get(data, "error", "unknown")
        code, _ = chat_slack_error(error isa AbstractString ? error : "unknown")
        throw(ChatError(code, "Slack connection rejected",
                        code == :rate_limited ? chat_retry_after(response.headers) : nothing))
    end
    url = get(data, "url", nothing)
    url isa AbstractString && ncodeunits(url) <= 8192 ||
        throw(ChatError(:io_error, "invalid Slack socket URL"))
    uri = try
        HTTP.URIs.URI(url)
    catch
        throw(ChatError(:io_error, "invalid Slack socket URL"))
    end
    uri.scheme == "wss" && !isempty(uri.host) && isempty(uri.userinfo) ||
        throw(ChatError(:io_error, "invalid Slack socket URL"))
    return String(url)
end

"""Ack first, then offer events without waiting for either the consumer or stdout."""
function chat_child_socket_frame(child::ChatChild, runtime::ChatChildWorkspace, ws, raw)
    data = try
        JSON.parse(String(raw))
    catch e
        chat_child_log(:invalid_socket_frame, e)
        return :ok
    end
    data isa AbstractDict || return :ok
    if haskey(data, "envelope_id")
        socket_send(ws, JSON.json(Dict("envelope_id" => data["envelope_id"])))
    end
    kind = get(data, "type", nothing)
    if kind == "hello"
        info = get(data, "connection_info", nothing)
        app_id = info isa AbstractDict ? get(info, "app_id", nothing) : nothing
        if chat_valid_id(app_id)
            if any(other -> other !== runtime && other.socket !== nothing && other.app_id == app_id,
                   values(child.workspaces))
                runtime.duplicate_app = true
                runtime.authenticated = false
                chat_child_status(child, runtime, "unavailable";
                                  error=ChatError(:duplicate_app, "workspace app already connected"))
                return :duplicate_app
            end
            runtime.app_id = String(app_id)
        end
        chat_child_status(child, runtime, "connected")
        runtime.connections > 1 && chat_child_emit(child, "gap",
            Dict("workspace" => runtime.workspace.id, "reason" => "reconnected"))
    elseif kind == "disconnect"
        return get(data, "reason", "") == "warning" ? :ok : :reconnect
    elseif kind == "events_api"
        payload = get(data, "payload", nothing)
        event = payload isa AbstractDict ? get(payload, "event", nothing) : nothing
        event isa AbstractDict || return :ok
        # Only this socket task produces queue entries. The consumer can only free
        # slots between this capacity check and put!, so put! cannot block on space.
        if Base.n_avail(runtime.queue) < runtime.capacity && isopen(runtime.queue)
            runtime.overflowing = false
            put!(runtime.queue, event)
        elseif !runtime.overflowing && !child.stopping
            runtime.overflowing = true
            chat_child_emit(child, "gap",
                Dict("workspace" => runtime.workspace.id, "reason" => "event_queue_overflow"))
        end
    end
    return :ok
end

"""Resolve Slack Connect file stubs without mutating the raw socket event."""
function chat_child_resolve_files(child::ChatChild, ws::ChatWorkspace, raw::AbstractDict)
    entries = get(raw, "files", nothing)
    entries isa AbstractVector || return raw
    files = Any[]
    for entry in entries
        file = entry
        if entry isa AbstractDict && get(entry, "file_access", "") == "check_file_info"
            child.stopping && return raw
            try
                file = chat_file_info(ws, get(entry, "id", nothing); timeout_s=child.options.meta_http_s)
            catch e
                chat_child_log(:file_stub_unresolved, e)
            end
        end
        child.stopping && return raw
        push!(files, file)
    end
    return merge(Dict{String,Any}(pairs(raw)), Dict("files" => files))
end

"""Normalize display events only: no directive, monitor, agent or proactive dispatch."""
function chat_child_message(child::ChatChild, runtime::ChatChildWorkspace, event::AbstractDict)
    get(event, "type", nothing) == "message" || return nothing
    channel = get(event, "channel", nothing)
    channel isa AbstractString && channel in runtime.workspace.channels || return nothing
    subtype = get(event, "subtype", nothing)
    if subtype == "message_deleted"
        ts = get(event, "deleted_ts", nothing)
        chat_valid_ts(ts) || return nothing
        chat_child_event(child, "changed", Dict("workspace" => runtime.workspace.id,
            "channel" => channel, "ts" => ts, "change" => "delete"))
        return nothing
    end
    edit = subtype == "message_changed"
    edit || subtype in (nothing, "", "thread_broadcast", "file_share", "bot_message", "me_message") ||
        return nothing
    raw = edit ? get(event, "message", nothing) : event
    raw isa AbstractDict || return nothing
    raw = chat_child_resolve_files(child, runtime.workspace, raw)
    child.stopping && return nothing
    record = normalize_message(runtime.workspace, raw, channel; timeout_s=child.options.meta_http_s)
    record === nothing && return nothing
    if edit
        chat_child_event(child, "changed", Dict("workspace" => runtime.workspace.id,
            "channel" => channel, "ts" => record["ts"], "change" => "edit", "message" => record))
    else
        chat_child_event(child, "message", record)
    end
    return nothing
end

"""Drain one workspace in order; failures never expose event or HTTP contents."""
function chat_child_consumer(child::ChatChild, runtime::ChatChildWorkspace)
    for event in runtime.queue
        child.stopping && break
        runtime.overflowing = false
        try
            chat_child_message(child, runtime, event)
        catch e
            child.output_failed || chat_child_log(:message_failed, e)
        end
    end
    return nothing
end

"""Wait for socket backoff, using a timer that shutdown can close immediately."""
function chat_child_backoff(child::ChatChild, runtime::ChatChildWorkspace, delay::Real)
    child.stopping && return nothing
    timer = Timer(max(0.001, Float64(delay)))
    runtime.retry_timer = timer
    try
        wait(timer)
    catch e
        child.stopping || rethrow()
    finally
        close(timer)
        runtime.retry_timer = nothing
    end
    return nothing
end

"""Share one bounded close between reconnect and shutdown, forcing silent peers off."""
function chat_child_close_socket(runtime::ChatChildWorkspace)
    runtime.socket === nothing && return nothing
    if runtime.close_task === nothing
        socket = runtime.socket
        runtime.close_task = @async begin
            closer = @async try
                close(socket)
            catch e
                chat_child_log(:socket_close_failed, e)
            end
            if timedwait(() -> istaskdone(closer), 2.0; pollint=0.01) == :timed_out
                try
                    socket_forceclose(socket)
                catch e
                    chat_child_log(:socket_forceclose_failed, e)
                end
            end
        end
    end
    return runtime.close_task
end

"""Maintain exactly one connection at a time for a configured workspace app."""
function chat_child_socket_loop(child::ChatChild, runtime::ChatChildWorkspace, socket_connect)
    backoff = 1.0
    chat_child_status(child, runtime, "connecting")
    while !child.stopping
        opened_at = nothing
        delay = backoff
        failure = nothing
        try
            if !runtime.authenticated
                chat_authenticate!(runtime.workspace; timeout_s=child.options.meta_http_s)
                runtime.authenticated = true
            end
            child.stopping && break
            url = chat_child_socket_url(runtime.workspace; timeout_s=child.options.meta_http_s)
            child.stopping && break
            socket_connect(url, ws -> begin
                runtime.socket = ws
                runtime.close_task = nothing
                runtime.connections += 1
                opened_at = time_ns()
                try
                    child.stopping && return nothing
                    for raw in socket_frames(ws)
                        child.stopping && break
                        chat_child_socket_frame(child, runtime, ws, raw) == :ok || break
                    end
                finally
                    # Close before the connector's own synchronous finally runs.
                    wait(chat_child_close_socket(runtime))
                end
            end)
        catch e
            child.stopping && break
            err = e isa ChatError ? e : ChatError(:io_error, "socket failure: $(nameof(typeof(e)))")
            failure = err
            chat_child_log(:socket_failed, e)
            if err.code in (:unauthorized, :forbidden)
                runtime.authenticated = false
                delay = 30.0
                backoff = 30.0
            elseif err.code == :rate_limited
                delay = something(err.retry_after_s, 30)
            end
        finally
            # The connector can still be in its close handshake after the callback
            # returns. Keep its identity reserved until that connection is retired.
            runtime.socket = nothing
            runtime.app_id = nothing
        end
        (child.stopping || runtime.duplicate_app) && break
        special_failure = failure !== nothing && failure.code in (:unauthorized, :forbidden, :rate_limited)
        if !special_failure && opened_at !== nothing && (time_ns() - opened_at) / 1e9 >= 60
            backoff = 1.0
            delay = 1.0
        end
        chat_child_status(child, runtime, "reconnecting")
        if special_failure
            state = failure.code == :rate_limited ? "limited" : "unavailable"
            chat_child_status(child, runtime, state; error=failure)
        end
        chat_child_backoff(child, runtime, delay)
        backoff = min(backoff * 2, 30.0)
    end
    return nothing
end

"""Claim one reply and always release its id, including after an output failure."""
function chat_child_finish(child::ChatChild, request::ChatChildRequest, payload)
    request.replied && return nothing
    request.replied = true
    request.timer === nothing || close(request.timer)
    if time() >= request.deadline_at
        outcome = chat_child_mutation(request.op) ?
            (get(payload, "outcome", "") == "refused" ? :refused : :unknown) : :none
        payload = chat_error_payload(ChatError(:timeout, "request deadline exceeded", nothing, outcome))
    end
    try
        chat_child_reply(child, request.id, request.op, payload)
    finally
        delete!(child.inflight, request.id)
        child.awaiting -= 1
        notify(child.settled)
    end
    return nothing
end

"""Admit one API task and race its result against a child-owned deadline."""
function chat_child_admit(child::ChatChild, id::Integer, op::String, payload::AbstractDict)
    child.stopping && throw(ChatError(:unavailable, "stopping"))
    workspace = get(payload, "workspace", nothing)
    workspace isa AbstractString && haskey(child.workspaces, workspace) ||
        throw(ChatError(:bad_request, "unknown workspace"))
    runtime = child.workspaces[workspace]
    runtime.authenticated || throw(ChatError(:unavailable, "workspace not authenticated"))
    ws = runtime.workspace
    channel = get(payload, "channel", nothing)
    channel isa AbstractString && channel in ws.channels ||
        throw(ChatError(:forbidden, "channel is not configured"))
    transfer = op in ("file.fetch", "file.upload")
    child.active < child.options.max_inflight || throw(ChatError(:busy, "request capacity reached"))
    !transfer || child.transfers < child.options.max_transfers ||
        throw(ChatError(:busy, "transfer capacity reached"))
    deadline = transfer ? child.options.file_deadline_s : child.options.meta_deadline_s
    request = ChatChildRequest(id, op, false, false, nothing, nothing, time() + deadline)
    push!(child.inflight, id)
    push!(child.requests, request)
    child.active += 1
    child.transfers += transfer
    child.awaiting += 1
    timeout_s = transfer ? child.options.file_http_s : child.options.meta_http_s
    request.timer = Timer(deadline) do timer
        request.cancelled = true
        try
            chat_child_finish(child, request, chat_error_payload(ChatError(:timeout, "request deadline exceeded",
                nothing, chat_outcome(chat_child_mutation(op), true))))
        catch e
            child.output_failed || chat_child_log(:deadline_output_failed, e)
        end
    end
    request.worker = @async begin
        try
            cancelled = () -> request.cancelled || child.stopping || time() >= request.deadline_at
            cancelled() && throw(ChatError(:timeout, "request cancelled"))
            request_ws = chat_child_cancellable_workspace(ws, cancelled)
            result = op == "history" ? chat_history(request_ws, payload; timeout_s) :
                     op == "post" ? chat_post(request_ws, payload; timeout_s) :
                     op == "file.fetch" ? chat_fetch_file(request_ws, payload; timeout_s) :
                     chat_upload_file(request_ws, payload; timeout_s, cancelled)
            chat_child_finish(child, request, result)
        catch e
            err = e isa ChatError ? e : ChatError(:io_error, "request failed: $(nameof(typeof(e)))",
                nothing, chat_outcome(chat_child_mutation(op), true))
            if chat_child_mutation(op) && err.outcome == :none
                err = ChatError(err.code, err.detail, err.retry_after_s, :refused)
            end
            try
                chat_child_finish(child, request, chat_error_payload(err))
            catch output_error
                child.output_failed || chat_child_log(:response_output_failed, output_error)
            end
        finally
            # Timed-out workers still occupy admission until they actually finish.
            # This keeps a transport that ignores timeouts from growing task counts.
            child.active -= 1
            child.transfers -= transfer
            filter!(pending -> pending !== request, child.requests)
        end
    end
    return nothing
end

"""Stop admission and start cancellation and socket retirement without waiting."""
function chat_child_begin_shutdown(child::ChatChild)
    child.stopping = true
    for request in child.requests
        request.cancelled = true
    end
    for runtime in values(child.workspaces)
        runtime.retry_timer === nothing || close(runtime.retry_timer)
        isopen(runtime.queue) && close(runtime.queue)
        chat_child_close_socket(runtime)
    end
    return nothing
end

# A cancelled worker needs time to observe cancellation and return.
const CHAT_CHILD_SHUTDOWN_GRACE_S = 1.0

"""Cancel workers, bound their drain by deadlines plus grace, and close sockets concurrently."""
function chat_child_shutdown(child::ChatChild)
    requests = copy(child.requests)
    chat_child_begin_shutdown(child)
    close_tasks = Task[runtime.close_task for runtime in values(child.workspaces)
                       if runtime.close_task !== nothing]
    if !isempty(requests)
        remaining = maximum(request.deadline_at for request in requests) + CHAT_CHILD_SHUTDOWN_GRACE_S - time()
        drained = () -> all(request -> request.worker === nothing || istaskdone(request.worker), requests)
        if !drained() && timedwait(drained, max(0.0, remaining); pollint=0.01) == :timed_out
            chat_child_log(:workers_pending_retirement)
        end
    end
    for task in close_tasks
        wait(task)
    end
    while child.awaiting > 0
        wait(child.settled)
    end
    return nothing
end

"""
    run_chat_child(input::IO, output::IO; transport=http_transport,
        socket_connect=default_socket_connect, meta_deadline_s=25, file_deadline_s=125,
        meta_http_s=20, file_http_s=120, max_inflight=16, max_transfers=2,
        queue_size=256, max_line=1 << 20, stderr=Base.stderr)

Serve bounded JSON lines until stop or EOF. Credentials arrive only in configure;
all Slack and socket work is separate from the protocol reader. API mutations are
submitted once, and a late result cannot replace a deadline's unknown outcome.
A write blocks while the reader of `output` stops draining it. The daemon owns
bounded retirement of a wedged child, including a stop reply blocked on output.
If a write or flush throws, close `input` to wake the reader and shut down.
"""
function run_chat_child(input::IO, output::IO; transport=http_transport,
                        socket_connect=default_socket_connect, meta_deadline_s=25, file_deadline_s=125,
                        meta_http_s=20, file_http_s=120, max_inflight=16, max_transfers=2,
                        queue_size=256, max_line=1 << 20, stderr::IO=Base.stderr)
    for value in (meta_deadline_s, file_deadline_s, meta_http_s, file_http_s)
        value isa Real && !(value isa Bool) && isfinite(value) && value > 0 ||
            throw(ArgumentError("chat time bounds must be positive and finite"))
    end
    for value in (max_inflight, max_transfers, queue_size, max_line)
        value isa Integer && !(value isa Bool) && 0 < value <= typemax(Int) ||
            throw(ArgumentError("chat capacities must be positive integers"))
    end
    max_line >= 256 || throw(ArgumentError("chat max_line must be at least 256 bytes"))
    return Base.CoreLogging.with_logger(ChatChildLogger(stderr)) do
        options = (; meta_deadline_s, file_deadline_s, meta_http_s, file_http_s,
                   max_inflight, max_transfers, queue_size, max_line)
        child = ChatChild(input, output, ReentrantLock(), options, Dict{String,ChatChildWorkspace}(),
                          String[], false, false, false, 0, 0, 0, Base.Condition(), Set{Integer}(), ChatChildRequest[])
        stop_id = nothing
        try
            chat_child_event(child, "ready", Dict("protocol" => 1))
            while !child.stopping
                kind, bytes = chat_child_readline(input, max_line)
                child.stopping && break
                kind == :eof && break
                if kind == :oversized
                    chat_child_log(:input_too_large)
                    continue
                end
                frame = try
                    JSON.parse(String(bytes))
                catch e
                    chat_child_log(:invalid_input_json, e)
                    continue
                end
                id = frame isa AbstractDict ? get(frame, "id", nothing) : nothing
                if !(id isa Integer) || id isa Bool
                    chat_child_log(:invalid_request_id)
                    continue
                end
                op = chat_child_op(get(frame, "op", nothing))
                try
                    version = get(frame, "v", nothing)
                    version isa Integer && !(version isa Bool) && version == 1 &&
                        get(frame, "kind", nothing) == "req" && !isempty(op) ||
                        throw(ChatError(:bad_request, "invalid request envelope"))
                    payload = get(frame, "payload", nothing)
                    payload isa AbstractDict || throw(ChatError(:bad_request, "invalid payload"))
                    id in child.inflight && throw(ChatError(:bad_request, "duplicate id"))
                    if op == "ping"
                        chat_child_reply(child, id, op, Dict{String,Any}())
                    elseif op == "stop"
                        stop_id = id
                        break
                    elseif op == "configure"
                        chat_child_configure(child, payload, transport)
                        chat_child_reply(child, id, op, Dict("accepted" => true))
                        for runtime in values(child.workspaces)
                            @async try
                                chat_child_consumer(child, runtime)
                            catch e
                                chat_child_log(:consumer_failed, e)
                            end
                            @async try
                                chat_child_socket_loop(child, runtime, socket_connect)
                            catch e
                                chat_child_log(:socket_loop_failed, e)
                            end
                        end
                    elseif op in ("history", "post", "file.fetch", "file.upload")
                        child.configured || throw(ChatError(:unavailable, "not configured"))
                        chat_child_admit(child, id, op, payload)
                    else
                        throw(ChatError(:bad_request, "unknown op"))
                    end
                catch e
                    child.output_failed && rethrow()
                    err = e isa ChatError ? e : ChatError(:io_error, "request failed: $(nameof(typeof(e)))")
                    if chat_child_mutation(op) && err.outcome == :none
                        err = ChatError(err.code, err.detail, err.retry_after_s, :refused)
                    end
                    chat_child_reply(child, id, op, chat_error_payload(err))
                end
            end
        catch
            child.output_failed || rethrow()
        finally
            chat_child_shutdown(child)
        end
        if stop_id !== nothing && !child.output_failed
            try
                chat_child_reply(child, stop_id, "stop", Dict("stopped" => true))
            catch
                child.output_failed || rethrow()
            end
        end
        return nothing
    end
end

"""Keep a duplicate of real stdout for frames and redirect incidental prints to stderr."""
function chat_child_main()
    flush(stdout)
    saved_stdout = stdout
    frame_fd = Base.Libc.dup(Base.RawFD(1))
    frame_fd == Base.RawFD(-1) && error("cannot preserve chat frame output")
    # open(RawFD) selects a libuv PipeEndpoint for daemon stdout. fdio would
    # create a synchronous IOStream whose blocked write could stall socket acks.
    frames_out = open(frame_fd)
    try
        redirect_stdout(stderr)
        Base.CoreLogging.with_logger(ChatChildLogger(stderr)) do
            try
                run_chat_child(stdin, frames_out)
            catch e
                chat_child_log(:child_failed, e)
            end
        end
    finally
        # The original stdout may itself wrap fd 1, changed by dup2 during
        # redirection. Restore that descriptor before restoring its Julia object.
        redirect_stdout(frames_out)
        redirect_stdout(saved_stdout)
        close(frames_out)
    end
    return nothing
end
