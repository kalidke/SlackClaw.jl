"""
Timer-based Slack polling loop with agent-loop dispatch.
Supports [CONTINUE]/[SCHEDULE] directives and status file watching.
"""

"""Track a conversation thread's Claude session."""
mutable struct ThreadSession
    thread_ts::String
    session_id::String
    last_reply_ts::String  # newest reply we've seen in this thread
    created::Float64       # time() when created, for expiry
    channel_id::String     # which channel this thread lives in
end

"""A scheduled future invocation."""
mutable struct ScheduledTask
    thread_ts::String
    session_id::String
    prompt::String
    due_at::Float64  # time() when this should fire
end

mutable struct MonitorState
    config::SlackClawConfig
    last_ts::String
    running::Bool
    active_tasks::Vector{Task}
    timer::Union{Timer,Nothing}
    threads::Dict{String,ThreadSession}  # thread_ts -> session
    busy_threads::Dict{String,Float64}   # thread_ts -> start time()
    scheduled::Vector{ScheduledTask}     # pending scheduled tasks
    listen_last_ts::Dict{String,String}  # channel_id -> last_ts for listen channels
    channel_names::Dict{String,String}   # channel_id -> display name (cached)
    last_proactive::Float64              # time() of last proactive check
    dispatch_lock::ReentrantLock         # guards cursor claims (socket events vs reconcile poll)
end

const SLACK_MAX_TEXT = 3900
const MAX_RESPONSE_CHUNKS = 10
const STATE_FILE = ".slackclaw_state.json"

# --- Persistence ---

"""Save full monitor state (threads, last_ts, scheduled tasks) to disk."""
function save_state!(state::MonitorState)
    path = joinpath(state.config.repo_dir, STATE_FILE)
    threads_data = Dict{String,Any}()
    for (ts, s) in state.threads
        threads_data[ts] = Dict(
            "thread_ts" => s.thread_ts,
            "session_id" => s.session_id,
            "last_reply_ts" => s.last_reply_ts,
            "created" => s.created,
            "channel_id" => s.channel_id,
        )
    end
    scheduled_data = [Dict(
        "thread_ts" => s.thread_ts,
        "session_id" => s.session_id,
        "prompt" => s.prompt,
        "due_at" => s.due_at,
    ) for s in state.scheduled]
    data = Dict(
        "last_ts" => state.last_ts,
        "threads" => threads_data,
        "scheduled" => scheduled_data,
        "listen_last_ts" => state.listen_last_ts,
        "last_proactive" => state.last_proactive,
    )
    open(path, "w") do io
        JSON.print(io, data)
    end
end

"""Load persisted state from disk. Returns (threads, last_ts, scheduled, listen_last_ts, last_proactive)."""
function load_state(config::SlackClawConfig)
    path = joinpath(config.repo_dir, STATE_FILE)
    threads = Dict{String,ThreadSession}()
    last_ts = ""
    scheduled = ScheduledTask[]
    listen_last_ts = Dict{String,String}()
    last_proactive = 0.0

    # Migrate old threads-only file if it exists
    old_path = joinpath(config.repo_dir, ".slackclaw_threads.json")
    if !isfile(path) && isfile(old_path)
        try
            data = JSON.parsefile(old_path)
            for (ts, d) in data
                threads[ts] = ThreadSession(
                    d["thread_ts"], d["session_id"],
                    d["last_reply_ts"], d["created"],
                    config.slack_channel_id)
            end
            @info "SlackClaw: migrated $(length(threads)) thread(s) from old format"
            return threads, last_ts, scheduled, listen_last_ts, last_proactive
        catch; end
    end

    isfile(path) || return threads, last_ts, scheduled, listen_last_ts, last_proactive
    try
        data = JSON.parsefile(path)
        last_ts = get(data, "last_ts", "")
        last_proactive = get(data, "last_proactive", 0.0)
        for (ts, d) in get(data, "threads", Dict())
            threads[ts] = ThreadSession(
                d["thread_ts"], d["session_id"],
                d["last_reply_ts"], d["created"],
                get(d, "channel_id", config.slack_channel_id))
        end
        now = time()
        for d in get(data, "scheduled", [])
            due = d["due_at"]
            due > now || continue  # skip expired scheduled tasks
            push!(scheduled, ScheduledTask(
                d["thread_ts"], d["session_id"], d["prompt"], due))
        end
        for (ch, ts) in get(data, "listen_last_ts", Dict())
            listen_last_ts[ch] = ts
        end
        @info "SlackClaw: loaded state — $(length(threads)) thread(s), $(length(scheduled)) scheduled task(s), last_ts=$last_ts"
    catch e
        @warn "SlackClaw: failed to load state file" exception=e
    end
    return threads, last_ts, scheduled, listen_last_ts, last_proactive
end

# --- Utilities ---

"""Format a Unix timestamp as a Slack-compatible ts string (no scientific notation)."""
function slack_ts_now()
    t = time()
    secs = floor(Int, t)
    frac = round(Int, (t - secs) * 1_000_000)
    return string(secs, ".", lpad(frac, 6, '0'))
end

"""
    chunk_text(text, limit=SLACK_MAX_TEXT) -> Vector{String}

Split text into chunks of at most `limit` characters, preferring to break at a
newline when one falls in the latter half of the window. Whitespace-only
chunks are dropped.
"""
function chunk_text(text::AbstractString, limit::Int=SLACK_MAX_TEXT)
    chunks = String[]
    rest = String(text)
    while length(rest) > limit
        window = first(rest, limit)
        nl = findlast('\n', window)
        take = (nl !== nothing && length(window[1:nl]) > limit ÷ 2) ? length(window[1:nl]) : limit
        chunk = String(rstrip(first(rest, take)))
        isempty(chunk) || push!(chunks, chunk)
        rest = lstrip(chop(rest; head=take, tail=0), '\n')
    end
    isempty(strip(rest)) || push!(chunks, String(rest))
    return chunks
end

"""Post a response to Slack, splitting long text across multiple thread messages."""
function post_response(config::SlackClawConfig, text::AbstractString, thread_ts::AbstractString;
                       channel_id::AbstractString=config.slack_channel_id)
    chunks = chunk_text(text)
    if length(chunks) > MAX_RESPONSE_CHUNKS
        chunks = chunks[1:MAX_RESPONSE_CHUNKS]
        chunks[end] *= "\n\n_(truncated after $(MAX_RESPONSE_CHUNKS) messages)_"
    end
    n = length(chunks)
    for (i, chunk) in enumerate(chunks)
        body = n > 1 ? "_($i/$n)_\n$chunk" : chunk
        slack_post_message(config, body; thread_ts, channel_id)
    end
end

# --- Cursor claims ---
# Shared dedup gate between the poll/reconcile paths and Socket Mode dispatch:
# atomically compare a message ts against its cursor and advance it. A message
# is dispatched only by whichever path claims it first; redeliveries and
# reconcile/socket overlap are dropped here.

"""Claim a top-level message against the primary-channel cursor. Returns false if already seen."""
function claim_primary!(state::MonitorState, ts::AbstractString)
    lock(state.dispatch_lock) do
        ts > state.last_ts || return false
        state.last_ts = ts
        return true
    end
end

"""Claim a thread reply against the session's reply cursor."""
function claim_thread_reply!(state::MonitorState, session::ThreadSession, ts::AbstractString)
    lock(state.dispatch_lock) do
        ts > session.last_reply_ts || return false
        session.last_reply_ts = ts
        return true
    end
end

"""Claim a listen-channel message against that channel's cursor."""
function claim_listen!(state::MonitorState, ch_id::AbstractString, ts::AbstractString)
    lock(state.dispatch_lock) do
        ts > get(state.listen_last_ts, ch_id, "") || return false
        state.listen_last_ts[ch_id] = ts
        return true
    end
end

# --- Status file watching ---

"""Watch status file during Claude execution, posting updates to thread."""
function watch_status_file(config::SlackClawConfig, thread_ts::String, stop::Ref{Bool};
                           channel_id::String=config.slack_channel_id)
    path = joinpath(config.repo_dir, config.status_file)
    last_content = ""
    while !stop[]
        for _ in 1:config.status_poll_s
            stop[] && return
            sleep(1)
        end
        try
            isfile(path) || continue
            content = strip(read(path, String))
            if !isempty(content) && content != last_content
                last_content = content
                slack_post_message(config, "_Status: $(content)_"; thread_ts, channel_id)
            end
        catch; end
    end
end

# --- Core loop ---

function start_monitor(config::SlackClawConfig)
    @info "SlackClaw: authenticating with Slack..."
    config.bot_user_id = slack_auth_test(config)
    @info "SlackClaw: bot user ID = $(config.bot_user_id)"

    threads, persisted_ts, scheduled, listen_last_ts, last_proactive = load_state(config)
    last_ts = isempty(persisted_ts) ? slack_ts_now() : persisted_ts

    # Resolve channel names for listen channels
    channel_names = Dict{String,String}()
    for ch_id in config.listen_channel_ids
        try
            info = slack_conversations_info(config, ch_id)
            channel_names[ch_id] = get(info, "name", ch_id)
            @info "SlackClaw: listen channel $(ch_id) → #$(channel_names[ch_id])"
        catch e
            @warn "SlackClaw: could not resolve channel name" channel_id=ch_id exception=e
            channel_names[ch_id] = ch_id
        end
        # Initialize last_ts for new listen channels
        if !haskey(listen_last_ts, ch_id)
            listen_last_ts[ch_id] = last_ts
        end
    end

    state = MonitorState(config, last_ts, true, Task[], nothing, threads,
                         Dict{String,Float64}(), scheduled, listen_last_ts,
                         channel_names, last_proactive, ReentrantLock())

    info_parts = ["Repo: `$(config.repo_dir)`"]
    !isempty(config.model) && push!(info_parts, "Model: `$(config.model)`")
    config.socket_mode && push!(info_parts, "Socket Mode")
    config.agent_directives && push!(info_parts, "Agent mode")
    !isempty(config.listen_channel_ids) && push!(info_parts,
        "Listening: $(join(["#$(get(channel_names, c, c))" for c in config.listen_channel_ids], ", "))")
    config.proactive_enabled && push!(info_parts,
        "Proactive: every $(div(config.proactive_interval_s, 60))m")
    slack_post_message(config,
        "_SlackClaw monitor started_ — watching this channel. " * join(info_parts, " | "))

    if config.socket_mode
        @info "SlackClaw: Socket Mode (reconcile every $(config.reconcile_interval_s)s)"
    else
        @info "SlackClaw: starting poll loop (interval=$(config.poll_interval_s)s)"
    end
    return state
end

function run_monitor(config::SlackClawConfig)
    crash_log = joinpath(config.repo_dir, ".slackclaw_crash.log")
    try
        if config.socket_mode && isempty(config.app_token)
            error("socket_mode=true but app_token is empty — set SLACK_APP_TOKEN " *
                  "(xapp- token with connections:write). There is no fallback to polling.")
        end
        state = start_monitor(config)
        try
            if config.socket_mode
                socket_loop!(state)
            else
                poll_loop!(state)
            end
        catch e
            e isa InterruptException || rethrow()
        finally
            stop_monitor!(state)
        end
    catch e
        open(crash_log, "a") do io
            println(io, "\n=== CRASH $(Dates.now()) ===")
            showerror(io, e, catch_backtrace())
            println(io)
        end
        @error "SlackClaw crashed — see $crash_log"
        rethrow()
    end
end

"""Polling-mode main loop. Runs until `state.running` is false."""
function poll_loop!(state::MonitorState)
    while state.running
        try
            poll_once!(state)
        catch e
            @error "SlackClaw poll error" exception=(e, catch_backtrace())
        end
        for _ in 1:state.config.poll_interval_s
            state.running || break
            sleep(1)
        end
    end
end

function poll_once!(state::MonitorState)
    state.running || return
    reconcile_messages!(state)
    check_scheduled!(state)
    check_proactive!(state)
end

"""
Fetch and dispatch anything newer than the cursors: primary-channel history,
tracked thread replies, listen channels. The whole message path of polling
mode; in Socket Mode this runs as the gap-fill reconciliation (on reconnect
and every `reconcile_interval_s`) — cursor claims drop anything the socket
already dispatched.
"""
function reconcile_messages!(state::MonitorState)
    state.running || return
    filter!(!istaskdone, state.active_tasks)

    n_threads = length(state.threads)
    n_sched = length(state.scheduled)
    @info "SlackClaw: polling (since $(state.last_ts), tasks=$(length(state.active_tasks)), threads=$n_threads, scheduled=$n_sched)"

    # 1. Top-level messages
    raw_msgs = slack_get_history(state.config, state.last_ts)
    @info "SlackClaw: got $(length(raw_msgs)) new channel message(s)"

    if !isempty(raw_msgs)
        parsed = parse_slack_messages(raw_msgs)
        for (msg, raw) in zip(parsed, raw_msgs)
            claim_primary!(state, msg.ts) || continue
            should_process(msg, state.config, raw) || continue
            dispatch_command!(state, msg)
        end
        save_state!(state)
    end

    # 2. Thread replies
    poll_threads!(state)

    # 3. Listen channels (respond in primary channel)
    poll_listen_channels!(state)
end

# --- Listen channel polling ---

"""Poll listen-only channels for new messages, dispatching responses to the primary channel."""
function poll_listen_channels!(state::MonitorState)
    config = state.config
    isempty(config.listen_channel_ids) && return

    for ch_id in config.listen_channel_ids
        state.running || break
        ch_last_ts = get(state.listen_last_ts, ch_id, state.last_ts)
        try
            raw_msgs = slack_get_history(config, ch_last_ts; channel_id=ch_id)
            isempty(raw_msgs) && continue

            ch_name = get(state.channel_names, ch_id, ch_id)
            parsed = parse_slack_messages(raw_msgs)
            for (msg, raw) in zip(parsed, raw_msgs)
                claim_listen!(state, ch_id, msg.ts) || continue
                should_process(msg, config, raw) || continue
                # Prefix message with channel origin for Claude context
                prefixed_text = "[from #$(ch_name)] $(msg.text)"
                prefixed_msg = SlackMessage(msg.ts, msg.user, prefixed_text, msg.thread_ts)
                # Dispatch to primary channel (no reaction on listen channel -- we're read-only)
                dispatch_listen_command!(state, prefixed_msg, ch_name)
            end
            save_state!(state)
        catch e
            @error "SlackClaw listen channel poll error" channel_id=ch_id exception=(e, catch_backtrace())
        end
        sleep(0.5)  # stagger polls to avoid rate limits
    end
end

const LISTEN_RELEVANCE_PREFIX = """You are monitoring a shared Slack channel for messages relevant to your repo/role. \
If the following message is NOT relevant to your project, respond with exactly "[SKIP]" and nothing else. \
If it IS relevant, respond normally.\n\n"""

"""Dispatch a message from a listen channel -- only post to primary channel if Claude deems it relevant."""
function dispatch_listen_command!(state::MonitorState, msg::SlackMessage, ch_name::String)
    config = state.config
    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        @info "SlackClaw: skipping listen channel message (busy)" channel=ch_name
        return
    end

    primary = config.slack_channel_id

    # Run Claude first to check relevance before posting anything
    task = @async begin
        try
            relevance_prompt = LISTEN_RELEVANCE_PREFIX * msg.text
            result = run_claude(relevance_prompt, config)

            # Skip if Claude says not relevant, errored, or empty
            response_text = strip(result.result_text)
            if !result.success || isempty(response_text) || startswith(response_text, "[SKIP]")
                @info "SlackClaw: listen message skipped (not relevant)" channel=ch_name
                return
            end

            # Relevant — post header + response as a new thread in primary channel
            header = "_Message from #$(ch_name):_\n> $(msg.text)"
            thread_ts = slack_post_message(config, header; channel_id=primary)
            post_response(config, response_text, thread_ts; channel_id=primary)

            # Track the thread for follow-up replies
            if !isempty(result.session_id)
                state.threads[thread_ts] = ThreadSession(
                    thread_ts, result.session_id, slack_ts_now(), time(), primary)
                save_state!(state)
            end
        catch e
            @error "SlackClaw listen dispatch error" channel=ch_name exception=(e, catch_backtrace())
        end
    end

    push!(state.active_tasks, task)
    return nothing
end

# --- Thread polling ---

function poll_threads!(state::MonitorState)
    for (thread_ts, session) in state.threads
        state.running || break
        try
            raw_replies = slack_get_replies(state.config, thread_ts, session.last_reply_ts;
                                           channel_id=session.channel_id)
            isempty(raw_replies) && continue
            parsed = parse_slack_messages(raw_replies)
            for (msg, raw) in zip(parsed, raw_replies)
                claim_thread_reply!(state, session, msg.ts) || continue
                should_process(msg, state.config, raw) || continue
                dispatch_thread_reply!(state, msg, session)
            end
        catch e
            @error "SlackClaw thread poll error" thread_ts exception=(e, catch_backtrace())
        end
    end
    save_state!(state)
    expire_threads!(state)
end

function expire_threads!(state::MonitorState)
    max = state.config.max_active_threads
    length(state.threads) <= max && return
    sorted = sort(collect(values(state.threads)); by=s -> s.created)
    to_remove = length(sorted) - max
    for i in 1:to_remove
        s = sorted[i]
        try
            slack_post_message(state.config,
                "_Thread closed — I can only track $(max) threads at a time. Start a new thread to continue._";
                thread_ts=s.thread_ts, channel_id=s.channel_id)
        catch; end
        delete!(state.threads, s.thread_ts)
    end
    @info "SlackClaw: expired $to_remove old thread(s)"
    save_state!(state)
end

# --- Scheduled tasks ---

function check_scheduled!(state::MonitorState)
    now = time()
    due = filter(s -> s.due_at <= now, state.scheduled)
    filter!(s -> s.due_at > now, state.scheduled)

    for sched in due
        @info "SlackClaw: firing scheduled task for thread $(sched.thread_ts)"
        ch = if haskey(state.threads, sched.thread_ts)
            state.threads[sched.thread_ts].channel_id
        else
            state.config.slack_channel_id
        end
        slack_post_message(state.config, "_Scheduled follow-up firing..._";
            thread_ts=sched.thread_ts, channel_id=ch)
        run_agent_loop!(state, sched.thread_ts, sched.prompt, sched.session_id;
                        channel_id=ch)
    end
end

# --- Proactive mode ---

const PROACTIVE_LOG_FILE = ".slackclaw_proactive_log"
const PROACTIVE_TASKS_FILE = ".slackclaw_proactive_tasks"

const PROACTIVE_PREFIX = """You are running a proactive check. \
If nothing is worth posting, respond with exactly "[SKIP]" and nothing else. \
Only post if you have something genuinely useful or interesting.

Read the proactive tasks file at "%TASKS_PATH%" for your current task suggestions. \
Read the proactive log file at "%LOG_PATH%" to see what you have posted recently. \
Do not repeat or re-report things already in the log. \
If you do post something, keep it concise.

"""

"""Check if a proactive run is due, and if so, run Claude with the proactive prompt."""
function check_proactive!(state::MonitorState)
    config = state.config
    config.proactive_enabled || return
    tasks_path = joinpath(config.repo_dir, PROACTIVE_TASKS_FILE)
    isempty(config.proactive_prompt) && !isfile(tasks_path) && return

    now = time()
    elapsed = now - state.last_proactive
    elapsed >= config.proactive_interval_s || return

    filter!(!istaskdone, state.active_tasks)
    if length(state.active_tasks) >= config.max_concurrent_tasks
        @info "SlackClaw: skipping proactive check (busy)"
        return
    end

    state.last_proactive = now
    save_state!(state)

    primary = config.slack_channel_id
    log_path = joinpath(config.repo_dir, PROACTIVE_LOG_FILE)

    task = @async begin
        try
            prefix = replace(replace(PROACTIVE_PREFIX,
                "%LOG_PATH%" => log_path),
                "%TASKS_PATH%" => tasks_path)
            prompt = prefix
            !isempty(config.proactive_prompt) && (prompt *= config.proactive_prompt)
            result = run_claude(prompt, config)

            response_text = strip(result.result_text)
            if !result.success || isempty(response_text) || startswith(response_text, "[SKIP]")
                @info "SlackClaw: proactive check — nothing to report"
                return
            end

            # Post as new top-level message in primary channel
            thread_ts = slack_post_message(config, response_text; channel_id=primary)

            # Append to proactive log
            try
                ts_str = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
                # Truncate response to a one-liner for the log
                summary = first(response_text, 200)
                summary = replace(summary, '\n' => ' ')
                open(log_path, "a") do io
                    println(io, "[$ts_str] $summary")
                end
            catch; end

            # Track thread for follow-up replies
            if !isempty(result.session_id)
                state.threads[thread_ts] = ThreadSession(
                    thread_ts, result.session_id, slack_ts_now(), time(), primary)
                save_state!(state)
            end

            @info "SlackClaw: proactive check posted to channel"
        catch e
            @error "SlackClaw proactive check error" exception=(e, catch_backtrace())
        end
    end

    push!(state.active_tasks, task)
    return nothing
end

# --- Agent loop: the core dispatch with CONTINUE/SCHEDULE support ---

"""
    run_agent_loop!(state, thread_ts, prompt, session_id; react_ts="", channel_id=state.config.slack_channel_id)

Run Claude in a loop, handling [CONTINUE] and [SCHEDULE] directives.
Posts each response to the thread. Watches status file during execution.
"""
function run_agent_loop!(state::MonitorState, thread_ts::String, prompt::String,
                         session_id::String; react_ts::String="",
                         channel_id::String=state.config.slack_channel_id)
    config = state.config
    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config, "Busy — please wait."; thread_ts, channel_id)
        return
    end

    state.busy_threads[thread_ts] = time()

    task = @async begin
        current_prompt = prompt
        current_session = session_id
        continue_count = 0

        try
            while true
                # Start status file watcher
                stop_watcher = Ref(false)
                watcher = @async watch_status_file(config, thread_ts, stop_watcher; channel_id)

                # Run Claude (pass thread context for file upload support)
                result = run_claude(current_prompt, config;
                    session_id=current_session,
                    thread_ts=thread_ts,
                    channel_id=channel_id)

                # Stop watcher
                stop_watcher[] = true

                # Update session tracking
                if !isempty(result.session_id)
                    current_session = result.session_id
                    state.threads[thread_ts] = ThreadSession(
                        thread_ts, current_session, slack_ts_now(), time(),
                        channel_id)
                    save_state!(state)
                end

                if !result.success
                    post_response(config, result.result_text, thread_ts; channel_id)
                    !isempty(react_ts) && slack_add_reaction(config, react_ts, "x"; channel_id)
                    break
                end

                # Parse directives
                directive, clean_text = if config.agent_directives
                    parse_directives(result.result_text)
                else
                    (DIRECTIVE_DONE, result.result_text)
                end

                # Post the clean response (directive-only messages leave clean_text empty)
                if !isempty(strip(clean_text))
                    post_response(config, clean_text, thread_ts; channel_id)
                elseif directive.type == :done
                    # Claude did work (tool use) but produced no text response
                    post_response(config, "_Done — changes applied._", thread_ts; channel_id)
                end

                if directive.type == :continue
                    continue_count += 1
                    if continue_count >= config.max_continue
                        slack_post_message(config,
                            "_Reached max continue limit ($(config.max_continue)). Stopping._";
                            thread_ts, channel_id)
                        break
                    end
                    @info "SlackClaw: [CONTINUE] #$continue_count in thread $thread_ts"
                    current_prompt = directive.prompt
                    # Loop continues immediately

                elseif directive.type == :schedule
                    due = time() + directive.delay_s
                    push!(state.scheduled, ScheduledTask(
                        thread_ts, current_session, directive.prompt, due))
                    save_state!(state)
                    mins = round(Int, directive.delay_s / 60)
                    slack_post_message(config,
                        "_Scheduled follow-up in $(mins)m._";
                        thread_ts, channel_id)
                    @info "SlackClaw: [SCHEDULE] $(directive.delay_s)s for thread $thread_ts"
                    break

                else  # :done
                    !isempty(react_ts) && slack_add_reaction(config, react_ts, "white_check_mark"; channel_id)
                    break
                end
            end
        catch e
            @error "SlackClaw agent loop error" exception=(e, catch_backtrace())
            try
                err_msg = e isa Exception ? string(typeof(e).name.name) : "Unknown error"
                slack_post_message(config, "Error: $err_msg (check server logs)"; thread_ts, channel_id)
                !isempty(react_ts) && slack_add_reaction(config, react_ts, "x"; channel_id)
            catch; end
        finally
            delete!(state.busy_threads, thread_ts)
            # Clean up status file
            status_path = joinpath(config.repo_dir, config.status_file)
            isfile(status_path) && rm(status_path; force=true)
        end
    end

    push!(state.active_tasks, task)
    return nothing
end

# --- Dispatch: top-level messages ---

function dispatch_command!(state::MonitorState, msg::SlackMessage;
                          channel_id::String=state.config.slack_channel_id)
    config = state.config

    # Dynamic proactive frequency adjustment
    m = match(r"proactive\s+(?:every|interval)\s+(\d+[hm]\w*)"i, msg.text)
    if m !== nothing
        new_interval = parse_duration(String(m.captures[1]))
        config.proactive_interval_s = new_interval
        mins = div(new_interval, 60)
        slack_post_message(config, "_Proactive interval set to $(mins)m._";
            thread_ts=msg.ts, channel_id)
        return
    end
    m = match(r"proactive\s+(on|off)"i, msg.text)
    if m !== nothing
        config.proactive_enabled = lowercase(m.captures[1]) == "on"
        status = config.proactive_enabled ? "enabled" : "disabled"
        slack_post_message(config, "_Proactive mode $(status)._";
            thread_ts=msg.ts, channel_id)
        return
    end

    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config,
            "Busy with $(length(state.active_tasks)) task(s) — please wait.";
            thread_ts=msg.ts, channel_id)
        return
    end

    slack_add_reaction(config, msg.ts, "eyes"; channel_id)
    run_agent_loop!(state, msg.ts, msg.text, ""; react_ts=msg.ts, channel_id)
end

# --- Dispatch: thread replies ---

function dispatch_thread_reply!(state::MonitorState, msg::SlackMessage, session::ThreadSession)
    config = state.config
    ch = session.channel_id

    # If thread is busy, report elapsed time
    if haskey(state.busy_threads, session.thread_ts)
        elapsed = round(Int, time() - state.busy_threads[session.thread_ts])
        mins, secs = divrem(elapsed, 60)
        elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
        slack_post_message(config,
            "_Still working... ($(elapsed_str) elapsed)_";
            thread_ts=session.thread_ts, channel_id=ch)
        return
    end

    slack_add_reaction(config, msg.ts, "eyes"; channel_id=ch)
    run_agent_loop!(state, session.thread_ts, msg.text, session.session_id;
                    react_ts=msg.ts, channel_id=ch)
end

# --- Shutdown ---

function stop_monitor!(state::MonitorState)
    @info "SlackClaw: stopping monitor..."
    state.running = false
    for t in state.active_tasks
        try wait(t) catch; end
    end
    empty!(state.active_tasks)
    try
        slack_post_message(state.config, "_SlackClaw monitor stopped._")
    catch; end
    @info "SlackClaw: stopped."
    return nothing
end
