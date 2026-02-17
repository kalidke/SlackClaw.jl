"""
Timer-based Slack polling loop and command dispatch with thread-persistent sessions.
"""

"""Track a conversation thread's Claude session."""
mutable struct ThreadSession
    thread_ts::String
    session_id::String
    last_reply_ts::String  # newest reply we've seen in this thread
    created::Float64       # time() when created, for expiry
end

mutable struct MonitorState
    config::SlackClawConfig
    last_ts::String
    running::Bool
    active_tasks::Vector{Task}
    timer::Union{Timer,Nothing}
    threads::Dict{String,ThreadSession}  # thread_ts -> session
    busy_threads::Dict{String,Float64}   # thread_ts -> start time()
end

const SLACK_MAX_TEXT = 3900  # leave room for formatting within 4000 char limit
const THREADS_FILE = ".slackclaw_threads.json"

"""Save thread sessions to disk."""
function save_threads!(state::MonitorState)
    path = joinpath(state.config.repo_dir, THREADS_FILE)
    data = Dict{String,Any}()
    for (ts, s) in state.threads
        data[ts] = Dict(
            "thread_ts" => s.thread_ts,
            "session_id" => s.session_id,
            "last_reply_ts" => s.last_reply_ts,
            "created" => s.created,
        )
    end
    open(path, "w") do io
        JSON.print(io, data)
    end
end

"""Load thread sessions from disk."""
function load_threads(config::SlackClawConfig)::Dict{String,ThreadSession}
    path = joinpath(config.repo_dir, THREADS_FILE)
    threads = Dict{String,ThreadSession}()
    isfile(path) || return threads
    try
        data = JSON.parsefile(path)
        for (ts, d) in data
            threads[ts] = ThreadSession(
                d["thread_ts"], d["session_id"],
                d["last_reply_ts"], d["created"])
        end
        @info "SlackClaw: loaded $(length(threads)) thread session(s) from disk"
    catch e
        @warn "SlackClaw: failed to load threads file" exception=e
    end
    return threads
end

"""Format a Unix timestamp as a Slack-compatible ts string (no scientific notation)."""
function slack_ts_now()
    t = time()
    secs = floor(Int, t)
    frac = round(Int, (t - secs) * 1_000_000)
    return string(secs, ".", lpad(frac, 6, '0'))
end

"""
    start_monitor(config::SlackClawConfig) -> MonitorState

Start polling the Slack channel for messages and dispatching them to Claude.
Returns a `MonitorState` that can be stopped with `stop_monitor!`.
"""
function start_monitor(config::SlackClawConfig)
    # Resolve bot user ID
    @info "SlackClaw: authenticating with Slack..."
    config.bot_user_id = slack_auth_test(config)
    @info "SlackClaw: bot user ID = $(config.bot_user_id)"

    threads = load_threads(config)
    state = MonitorState(config, slack_ts_now(), true, Task[], nothing, threads,
                         Dict{String,Float64}())

    # Post startup message
    info_parts = ["Repo: `$(config.repo_dir)`"]
    !isempty(config.model) && push!(info_parts, "Model: `$(config.model)`")
    config.max_budget_usd > 0 && push!(info_parts, "Budget: \$$(config.max_budget_usd)/task")
    slack_post_message(config,
        "_SlackClaw monitor started_ — watching this channel. " * join(info_parts, " | "))

    @info "SlackClaw: starting poll loop (interval=$(config.poll_interval_s)s)"

    return state
end

"""
    run_monitor(config::SlackClawConfig)

Start the monitor and block, polling in a loop. Stops on interrupt.
"""
function run_monitor(config::SlackClawConfig)
    state = start_monitor(config)
    try
        while state.running
            try
                poll_once!(state)
            catch e
                @error "SlackClaw poll error" exception=(e, catch_backtrace())
            end
            # Sleep in small increments so we can stop quickly
            for _ in 1:state.config.poll_interval_s
                state.running || break
                sleep(1)
            end
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        stop_monitor!(state)
    end
end

"""
    poll_once!(state::MonitorState)

Fetch new top-level messages and poll active threads for replies.
"""
function poll_once!(state::MonitorState)
    state.running || return

    # Clean up finished tasks
    filter!(!istaskdone, state.active_tasks)

    n_threads = length(state.threads)
    @info "SlackClaw: polling (since $(state.last_ts), active_tasks=$(length(state.active_tasks)), threads=$n_threads)"

    # 1. Poll top-level channel messages
    raw_msgs = slack_get_history(state.config, state.last_ts)
    @info "SlackClaw: got $(length(raw_msgs)) new channel message(s)"

    if !isempty(raw_msgs)
        parsed = parse_slack_messages(raw_msgs)
        for (msg, raw) in zip(parsed, raw_msgs)
            if msg.ts > state.last_ts
                state.last_ts = msg.ts
            end
            should_process(msg, state.config, raw) || continue
            dispatch_command!(state, msg)
        end
    end

    # 2. Poll active threads for new replies
    poll_threads!(state)
end

"""
    poll_threads!(state::MonitorState)

Check each active thread for new user replies and dispatch them.
"""
function poll_threads!(state::MonitorState)
    for (thread_ts, session) in state.threads
        state.running || break
        try
            raw_replies = slack_get_replies(state.config, thread_ts, session.last_reply_ts)
            isempty(raw_replies) && continue

            parsed = parse_slack_messages(raw_replies)
            for (msg, raw) in zip(parsed, raw_replies)
                if msg.ts > session.last_reply_ts
                    session.last_reply_ts = msg.ts
                end
                should_process(msg, state.config, raw) || continue
                dispatch_thread_reply!(state, msg, session)
            end
        catch e
            @error "SlackClaw thread poll error" thread_ts exception=(e, catch_backtrace())
        end
    end

    # Expire old threads beyond the limit (keep most recent)
    expire_threads!(state)
end

"""
    expire_threads!(state::MonitorState)

Remove oldest threads when exceeding `max_active_threads`.
"""
function expire_threads!(state::MonitorState)
    max = state.config.max_active_threads
    length(state.threads) <= max && return
    # Sort by creation time, remove oldest
    sorted = sort(collect(values(state.threads)); by=s -> s.created)
    to_remove = length(sorted) - max
    for i in 1:to_remove
        delete!(state.threads, sorted[i].thread_ts)
    end
    @info "SlackClaw: expired $to_remove old thread(s)"
    save_threads!(state)
end

"""
    dispatch_command!(state::MonitorState, msg::SlackMessage)

Handle a new top-level message: start a fresh Claude session, reply in thread.
"""
function dispatch_command!(state::MonitorState, msg::SlackMessage)
    config = state.config

    # Clean up finished tasks
    filter!(!istaskdone, state.active_tasks)

    # Concurrency check
    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config,
            "Busy with $(length(state.active_tasks)) task(s) — please wait.";
            thread_ts=msg.ts)
        return
    end

    # React with :eyes: to acknowledge
    slack_add_reaction(config, msg.ts, "eyes")

    state.busy_threads[msg.ts] = time()

    task = @async begin
        try
            # Run Claude (new session)
            result = run_claude(msg.text, config)

            # Format response
            response = result.result_text
            if length(response) > SLACK_MAX_TEXT
                response = response[1:SLACK_MAX_TEXT] * "\n\n_(truncated)_"
            end

            # Post result as thread reply
            slack_post_message(config, response; thread_ts=msg.ts)

            # Track this thread for follow-ups if we got a session_id
            if !isempty(result.session_id)
                state.threads[msg.ts] = ThreadSession(
                    msg.ts, result.session_id, slack_ts_now(), time())
                @info "SlackClaw: new thread session $(result.session_id) for thread $(msg.ts)"
                save_threads!(state)
            end

            # React with status emoji
            emoji = result.success ? "white_check_mark" : "x"
            slack_add_reaction(config, msg.ts, emoji)
        catch e
            @error "SlackClaw dispatch error" exception=(e, catch_backtrace())
            try
                err_msg = e isa Exception ? string(typeof(e).name.name) : "Unknown error"
                slack_post_message(config, "Error: $err_msg (check server logs)";
                    thread_ts=msg.ts)
                slack_add_reaction(config, msg.ts, "x")
            catch; end
        finally
            delete!(state.busy_threads, msg.ts)
        end
    end

    push!(state.active_tasks, task)
    return nothing
end

"""
    dispatch_thread_reply!(state::MonitorState, msg::SlackMessage, session::ThreadSession)

Handle a reply in an active thread: resume the existing Claude session.
"""
function dispatch_thread_reply!(state::MonitorState, msg::SlackMessage, session::ThreadSession)
    config = state.config

    # If this thread has an active task, report elapsed time instead
    if haskey(state.busy_threads, session.thread_ts)
        elapsed = round(Int, time() - state.busy_threads[session.thread_ts])
        mins, secs = divrem(elapsed, 60)
        elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
        slack_post_message(config,
            "_Still working... ($(elapsed_str) elapsed)_";
            thread_ts=session.thread_ts)
        return
    end

    # Clean up finished tasks
    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config,
            "Busy with $(length(state.active_tasks)) task(s) — please wait.";
            thread_ts=session.thread_ts)
        return
    end

    slack_add_reaction(config, msg.ts, "eyes")

    state.busy_threads[session.thread_ts] = time()

    task = @async begin
        try
            # Resume existing Claude session
            result = run_claude(msg.text, config; session_id=session.session_id)

            # Update session_id in case it changed
            if !isempty(result.session_id) && result.session_id != session.session_id
                session.session_id = result.session_id
                save_threads!(state)
            end

            response = result.result_text
            if length(response) > SLACK_MAX_TEXT
                response = response[1:SLACK_MAX_TEXT] * "\n\n_(truncated)_"
            end

            slack_post_message(config, response; thread_ts=session.thread_ts)

            emoji = result.success ? "white_check_mark" : "x"
            slack_add_reaction(config, msg.ts, emoji)
        catch e
            @error "SlackClaw thread dispatch error" exception=(e, catch_backtrace())
            try
                err_msg = e isa Exception ? string(typeof(e).name.name) : "Unknown error"
                slack_post_message(config, "Error: $err_msg (check server logs)";
                    thread_ts=session.thread_ts)
                slack_add_reaction(config, msg.ts, "x")
            catch; end
        finally
            delete!(state.busy_threads, session.thread_ts)
        end
    end

    push!(state.active_tasks, task)
    return nothing
end

"""
    stop_monitor!(state::MonitorState)

Stop the polling loop and wait for active tasks to finish.
"""
function stop_monitor!(state::MonitorState)
    @info "SlackClaw: stopping monitor..."
    state.running = false
    # Wait for active tasks (with timeout)
    for t in state.active_tasks
        try
            wait(t)
        catch; end
    end
    empty!(state.active_tasks)
    try
        slack_post_message(state.config, "_SlackClaw monitor stopped._")
    catch; end
    @info "SlackClaw: stopped."
    return nothing
end
