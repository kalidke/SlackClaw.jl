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
end

const SLACK_MAX_TEXT = 3900
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
    )
    open(path, "w") do io
        JSON.print(io, data)
    end
end

"""Load persisted state from disk. Returns (threads, last_ts, scheduled)."""
function load_state(config::SlackClawConfig)
    path = joinpath(config.repo_dir, STATE_FILE)
    threads = Dict{String,ThreadSession}()
    last_ts = ""
    scheduled = ScheduledTask[]

    # Migrate old threads-only file if it exists
    old_path = joinpath(config.repo_dir, ".slackclaw_threads.json")
    if !isfile(path) && isfile(old_path)
        try
            data = JSON.parsefile(old_path)
            for (ts, d) in data
                threads[ts] = ThreadSession(
                    d["thread_ts"], d["session_id"],
                    d["last_reply_ts"], d["created"])
            end
            @info "SlackClaw: migrated $(length(threads)) thread(s) from old format"
            return threads, last_ts, scheduled
        catch; end
    end

    isfile(path) || return threads, last_ts, scheduled
    try
        data = JSON.parsefile(path)
        last_ts = get(data, "last_ts", "")
        for (ts, d) in get(data, "threads", Dict())
            threads[ts] = ThreadSession(
                d["thread_ts"], d["session_id"],
                d["last_reply_ts"], d["created"])
        end
        now = time()
        for d in get(data, "scheduled", [])
            due = d["due_at"]
            due > now || continue  # skip expired scheduled tasks
            push!(scheduled, ScheduledTask(
                d["thread_ts"], d["session_id"], d["prompt"], due))
        end
        @info "SlackClaw: loaded state — $(length(threads)) thread(s), $(length(scheduled)) scheduled task(s), last_ts=$last_ts"
    catch e
        @warn "SlackClaw: failed to load state file" exception=e
    end
    return threads, last_ts, scheduled
end

# --- Utilities ---

"""Format a Unix timestamp as a Slack-compatible ts string (no scientific notation)."""
function slack_ts_now()
    t = time()
    secs = floor(Int, t)
    frac = round(Int, (t - secs) * 1_000_000)
    return string(secs, ".", lpad(frac, 6, '0'))
end

"""Post a response to Slack, truncating if needed."""
function post_response(config::SlackClawConfig, text::String, thread_ts::String)
    if length(text) > SLACK_MAX_TEXT
        text = text[1:SLACK_MAX_TEXT] * "\n\n_(truncated)_"
    end
    slack_post_message(config, text; thread_ts)
end

# --- Status file watching ---

"""Watch status file during Claude execution, posting updates to thread."""
function watch_status_file(config::SlackClawConfig, thread_ts::String, stop::Ref{Bool})
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
                slack_post_message(config, "_Status: $(content)_"; thread_ts)
            end
        catch; end
    end
end

# --- Core loop ---

function start_monitor(config::SlackClawConfig)
    @info "SlackClaw: authenticating with Slack..."
    config.bot_user_id = slack_auth_test(config)
    @info "SlackClaw: bot user ID = $(config.bot_user_id)"

    threads, persisted_ts, scheduled = load_state(config)
    last_ts = isempty(persisted_ts) ? slack_ts_now() : persisted_ts
    state = MonitorState(config, last_ts, true, Task[], nothing, threads,
                         Dict{String,Float64}(), scheduled)

    info_parts = ["Repo: `$(config.repo_dir)`"]
    !isempty(config.model) && push!(info_parts, "Model: `$(config.model)`")
    config.agent_directives && push!(info_parts, "Agent mode")
    slack_post_message(config,
        "_SlackClaw monitor started_ — watching this channel. " * join(info_parts, " | "))

    @info "SlackClaw: starting poll loop (interval=$(config.poll_interval_s)s)"
    return state
end

function run_monitor(config::SlackClawConfig)
    state = start_monitor(config)
    try
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
    catch e
        e isa InterruptException || rethrow()
    finally
        stop_monitor!(state)
    end
end

function poll_once!(state::MonitorState)
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
            if msg.ts > state.last_ts
                state.last_ts = msg.ts
            end
            should_process(msg, state.config, raw) || continue
            dispatch_command!(state, msg)
        end
        save_state!(state)
    end

    # 2. Thread replies
    poll_threads!(state)

    # 3. Scheduled tasks
    check_scheduled!(state)
end

# --- Thread polling ---

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
    expire_threads!(state)
end

function expire_threads!(state::MonitorState)
    max = state.config.max_active_threads
    length(state.threads) <= max && return
    sorted = sort(collect(values(state.threads)); by=s -> s.created)
    to_remove = length(sorted) - max
    for i in 1:to_remove
        delete!(state.threads, sorted[i].thread_ts)
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
        slack_post_message(state.config, "_Scheduled follow-up firing..._";
            thread_ts=sched.thread_ts)
        run_agent_loop!(state, sched.thread_ts, sched.prompt, sched.session_id)
    end
end

# --- Agent loop: the core dispatch with CONTINUE/SCHEDULE support ---

"""
    run_agent_loop!(state, thread_ts, prompt, session_id; react_ts="")

Run Claude in a loop, handling [CONTINUE] and [SCHEDULE] directives.
Posts each response to the thread. Watches status file during execution.
"""
function run_agent_loop!(state::MonitorState, thread_ts::String, prompt::String,
                         session_id::String; react_ts::String="")
    config = state.config
    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config, "Busy — please wait."; thread_ts)
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
                watcher = @async watch_status_file(config, thread_ts, stop_watcher)

                # Run Claude
                result = run_claude(current_prompt, config; session_id=current_session)

                # Stop watcher
                stop_watcher[] = true

                # Update session tracking
                if !isempty(result.session_id)
                    current_session = result.session_id
                    state.threads[thread_ts] = ThreadSession(
                        thread_ts, current_session, slack_ts_now(), time())
                    save_state!(state)
                end

                if !result.success
                    post_response(config, result.result_text, thread_ts)
                    !isempty(react_ts) && slack_add_reaction(config, react_ts, "x")
                    break
                end

                # Parse directives
                directive, clean_text = if config.agent_directives
                    parse_directives(result.result_text)
                else
                    (DIRECTIVE_DONE, result.result_text)
                end

                # Post the clean response
                post_response(config, clean_text, thread_ts)

                if directive.type == :continue
                    continue_count += 1
                    if continue_count >= config.max_continue
                        slack_post_message(config,
                            "_Reached max continue limit ($(config.max_continue)). Stopping._";
                            thread_ts)
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
                        thread_ts)
                    @info "SlackClaw: [SCHEDULE] $(directive.delay_s)s for thread $thread_ts"
                    break

                else  # :done
                    !isempty(react_ts) && slack_add_reaction(config, react_ts, "white_check_mark")
                    break
                end
            end
        catch e
            @error "SlackClaw agent loop error" exception=(e, catch_backtrace())
            try
                err_msg = e isa Exception ? string(typeof(e).name.name) : "Unknown error"
                slack_post_message(config, "Error: $err_msg (check server logs)"; thread_ts)
                !isempty(react_ts) && slack_add_reaction(config, react_ts, "x")
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

function dispatch_command!(state::MonitorState, msg::SlackMessage)
    config = state.config
    filter!(!istaskdone, state.active_tasks)

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config,
            "Busy with $(length(state.active_tasks)) task(s) — please wait.";
            thread_ts=msg.ts)
        return
    end

    slack_add_reaction(config, msg.ts, "eyes")
    run_agent_loop!(state, msg.ts, msg.text, ""; react_ts=msg.ts)
end

# --- Dispatch: thread replies ---

function dispatch_thread_reply!(state::MonitorState, msg::SlackMessage, session::ThreadSession)
    config = state.config

    # If thread is busy, report elapsed time
    if haskey(state.busy_threads, session.thread_ts)
        elapsed = round(Int, time() - state.busy_threads[session.thread_ts])
        mins, secs = divrem(elapsed, 60)
        elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
        slack_post_message(config,
            "_Still working... ($(elapsed_str) elapsed)_";
            thread_ts=session.thread_ts)
        return
    end

    slack_add_reaction(config, msg.ts, "eyes")
    run_agent_loop!(state, session.thread_ts, msg.text, session.session_id; react_ts=msg.ts)
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
