"""
Timer-based Slack polling loop with agent-loop dispatch.
Supports [CONTINUE]/[SCHEDULE] directives and status file watching.
"""

"""Track a conversation thread's Claude session."""
mutable struct ThreadSession
    thread_ts::String
    session_id::String
    last_reply_ts::String  # newest reply we've seen in this thread
    created::Float64       # time() of the last run recorded (track_thread!), for expiry and the cap
    channel_id::String     # which channel this thread lives in
end

"""A scheduled future invocation. `deferred` marks one that came due but had to
wait (its thread was running, or no slot was free): it is kept across a restart
even once its time has passed, where a follow-up that never came due is not."""
mutable struct ScheduledTask
    thread_ts::String
    session_id::String
    prompt::String
    due_at::Float64  # time() when this should fire
    deferred::Bool
end

ScheduledTask(thread_ts, session_id, prompt, due_at) =
    ScheduledTask(thread_ts, session_id, prompt, due_at, false)

"""
Runtime state of a monitor: cursors, tracked threads, scheduled tasks, and
the active task list. Created by [`start_monitor`](@ref); persisted to
`.slackclaw_state.json` in `repo_dir` across restarts.
"""
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

"""Reply token by which Claude declines to post (listen relevance, proactive, and — when
`allow_skip` is set — the primary/thread path)."""
const SKIP_TOKEN = "[SKIP]"

"""
    should_skip_response(text, allow_skip) -> Bool

Whether a primary/thread-path response should be silently dropped. Requires an
EXACT match (`strip(text) == SKIP_TOKEN`), unlike the [`is_decline`](@ref)
containment checks on the listen and proactive paths: there a false positive
only suppresses optional chatter, but here it would eat a real answer in the
user's own channel — e.g. a reply that legitimately opens by quoting the token
while explaining this feature. Missing a skip is cheap; eating an answer is not.
"""
should_skip_response(text::AbstractString, allow_skip::Bool) =
    allow_skip && strip(text) == SKIP_TOKEN

"""
    is_decline(text) -> Bool

Whether a listen/proactive response declines to post: CONTAINMENT match
(`occursin(SKIP_TOKEN, text)`). Models reliably narrate a decline and leave the
token at the END ("…nothing new to report. [SKIP]"), which the old prefix check
posted verbatim as channel spam — and prompt hardening empirically failed to
stop it. On these two paths the cost asymmetry is the OPPOSITE of
[`should_skip_response`](@ref): a false positive merely suppresses an optional
post (silent, cheap), a false negative is user-visible spam.
"""
is_decline(text::AbstractString) = occursin(SKIP_TOKEN, text)

# --- Persistence ---

"""Save full monitor state (threads, last_ts, scheduled tasks) to disk."""
function save_state!(state::MonitorState)
    path = joinpath(state.config.repo_dir, state.config.state_file)
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
        "deferred" => s.deferred,
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
    path = joinpath(config.repo_dir, config.state_file)
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
            deferred = get(d, "deferred", false) === true
            # Skip follow-ups whose time passed while the monitor was down; keep
            # one that came due and was waiting for its thread, for up to a day
            # (after a longer stop it would fire at once in a stale thread)
            due > now || (deferred && now - due < 86400) || continue
            push!(scheduled, ScheduledTask(
                d["thread_ts"], d["session_id"], d["prompt"], due, deferred))
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

"""
Claim a thread reply against the session's reply cursor. Fails when `session` is
no longer the thread's tracked entry (it expired, or was re-tracked, while the
caller held it across a yield): its cursor is dead, and a claim on it would
dispatch a reply the live entry may already have.
"""
function claim_thread_reply!(state::MonitorState, session::ThreadSession, ts::AbstractString)
    lock(state.dispatch_lock) do
        get(state.threads, session.thread_ts, nothing) === session || return false
        ts > session.last_reply_ts || return false
        session.last_reply_ts = ts
        return true
    end
end

"""
Claim a user reply that arrived in an expired/untracked thread by atomically
re-tracking it. Creates a fresh `ThreadSession` — empty Claude `session_id`,
since the expired session's context is gone; the reply starts a new session in
the same Slack thread — with `last_reply_ts = msg.ts`, so a redelivery of this
message routes as `:thread_reply` and fails `claim_thread_reply!`. Returns the
new session, or `nothing` when the thread is already tracked (another delivery
won the race).
"""
function claim_thread_revive!(state::MonitorState, msg::SlackMessage, channel_id::AbstractString)
    lock(state.dispatch_lock) do
        haskey(state.threads, msg.thread_ts) && return nothing
        session = ThreadSession(msg.thread_ts, "", msg.ts, time(), String(channel_id))
        state.threads[msg.thread_ts] = session
        return session
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
        stop[] && return  # the run ended during the last sleep
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

"""
    start_monitor(config::SlackClawConfig) -> MonitorState

Authenticate with Slack, load persisted state, resolve listen-channel names,
and post the startup banner. Returns the [`MonitorState`](@ref) without
entering a message loop — use [`run_monitor`](@ref) for the blocking
entry point, or run `socket_loop!` yourself and call
[`stop_monitor!`](@ref) when done.
"""
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

    if config.announce_startup
        info_parts = ["Repo: `$(config.repo_dir)`"]
        !isempty(config.model) && push!(info_parts, "Model: `$(config.model)`")
        config.agent_directives && push!(info_parts, "Agent mode")
        !isempty(config.listen_channel_ids) && push!(info_parts,
            "Listening: $(join(["#$(get(channel_names, c, c))" for c in config.listen_channel_ids], ", "))")
        config.proactive_enabled && push!(info_parts,
            "Proactive: every $(div(config.proactive_interval_s, 60))m")
        slack_post_message(config,
            "_SlackClaw monitor started_ — watching this channel. " * join(info_parts, " | "))
    end

    @info "SlackClaw: Socket Mode (reconcile every $(config.reconcile_interval_s)s)"
    return state
end

"""
    run_monitor(config::SlackClawConfig)

Blocking entry point for a single channel. Connects via Slack Socket Mode and
serves pushed message events until interrupted (Ctrl-C). Requires
`config.app_token` (an `xapp-` app-level token with `connections:write`) and
errors at startup if it is empty. To serve many channels of one workspace over
a single socket, use [`run_socket_fleet`](@ref). Fatal errors are appended to
`.slackclaw_crash.log` in `repo_dir` before rethrowing.
"""
function run_monitor(config::SlackClawConfig)
    crash_log = joinpath(config.repo_dir, ".slackclaw_crash.log")
    try
        isempty(config.app_token) &&
            error("app_token is empty — set SLACK_APP_TOKEN (xapp- token with " *
                  "connections:write scope). Run SlackClaw.setup() to provision it.")
        state = start_monitor(config)
        try
            socket_loop!(state)
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

"""
Gap-fill reconciliation: fetch and dispatch anything newer than the cursors —
primary-channel history, tracked thread replies, and listen channels. Socket
Mode delivery is at-least-once with gaps across reconnects, so this runs on
every (re)connect and every `reconcile_interval_s`; the `claim_*!` cursor gates
drop anything the live socket already dispatched.
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
                # Prefix message with sender + channel origin for Claude context
                prefixed_msg = listen_attributed_message(msg, ch_name)
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
If the following message is NOT relevant to your project, respond with exactly "$(SKIP_TOKEN)" and nothing else. \
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
            if !result.success || isempty(response_text) || is_decline(response_text)
                @info "SlackClaw: listen message skipped (not relevant)" channel=ch_name
                return
            end

            # Relevant — post header + response as a new thread in primary channel
            header = "_Message from #$(ch_name):_\n> $(msg.text)"
            thread_ts = slack_post_message(config, header; channel_id=primary)
            post_response(config, response_text, thread_ts; channel_id=primary)

            # Track the thread for follow-up replies
            if !isempty(result.session_id)
                track_thread!(state, thread_ts, primary; session_id=result.session_id)
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
    # A snapshot: agent-loop tasks add threads while this loop waits on Slack
    for (thread_ts, session) in collect(state.threads)
        state.running || break
        try
            raw_replies = slack_get_replies(state.config, thread_ts, session.last_reply_ts;
                                           channel_id=session.channel_id)
            isempty(raw_replies) && continue
            parsed = parse_slack_messages(raw_replies)
            for (msg, raw) in zip(parsed, raw_replies)
                # Fails once the thread expired or was re-tracked (during the
                # call, or while an earlier reply here dispatched): the next poll
                # reads the rest against the live cursor
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

"""Last-activity time for a thread session: newest reply seen, or creation time."""
function thread_last_active(s::ThreadSession)
    t = tryparse(Float64, s.last_reply_ts)
    return t === nothing ? s.created : max(s.created, t)
end

"""Sessions idle longer than `idle_cutoff_s` as of `now` (none when cutoff is 0)."""
function idle_expired_threads(threads::Dict{String,ThreadSession}, idle_cutoff_s::Int, now::Float64)
    idle_cutoff_s > 0 || return ThreadSession[]
    return [s for s in values(threads) if now - thread_last_active(s) > idle_cutoff_s]
end

"""
Drop threads idle beyond `max_thread_idle_s`, then enforce the
`max_active_threads` count cap (oldest first). Every tracked thread costs a
`conversations.replies` call per poll/reconcile cycle, so unbounded idle
threads become permanent rate-limit pressure. Expiry is SILENT — no notice is
posted (a bookkeeping announcement only pulls readers back into a dead
thread). A later user reply in an expired thread re-tracks it via the
`:thread_revive` route (fresh Claude session, same Slack thread), so expiry
costs the user nothing but the dropped conversation context.

A thread with work still to come (a run in flight, or a scheduled follow-up
pending) is never expired: the run's end, or the follow-up, would track it again
with a fresh cursor and lose the reply cursor it had.
"""
function expire_threads!(state::MonitorState)
    dropped = 0
    pending = Set(s.thread_ts for s in state.scheduled)
    evictable(s) = !haskey(state.busy_threads, s.thread_ts) && !(s.thread_ts in pending)

    for s in idle_expired_threads(state.threads, state.config.max_thread_idle_s, time())
        evictable(s) || continue
        delete!(state.threads, s.thread_ts)
        dropped += 1
    end

    # The cap counts evictable threads only: threads kept for work to come sit
    # beside it, so they never push out a recent conversation
    cap = state.config.max_active_threads
    sorted = sort(filter(evictable, collect(values(state.threads))); by=s -> s.created)
    for s in first(sorted, Base.max(length(sorted) - cap, 0))
        delete!(state.threads, s.thread_ts)
        dropped += 1
    end

    dropped == 0 && return
    @info "SlackClaw: expired $dropped thread(s)"
    save_state!(state)
end

# --- Scheduled tasks ---

function check_scheduled!(state::MonitorState)
    now = time()
    filter!(!istaskdone, state.active_tasks)
    fired = ScheduledTask[]
    waiting = false
    # No yield in this loop: each due follow-up stays in `state.scheduled` (so
    # its thread cannot expire) until its run has the thread and a slot, and
    # nothing else can take either between the check and the start.
    for sched in filter(s -> s.due_at <= now, state.scheduled)
        # A follow-up whose thread is running, or with no free slot, waits until
        # both are free: two runs in one thread would write the same session.
        # It is marked deferred, so a restart (which drops follow-ups whose time
        # passed while the monitor was down) keeps it.
        if haskey(state.busy_threads, sched.thread_ts) ||
           length(state.active_tasks) >= state.config.max_concurrent_tasks
            sched.deferred = true
            waiting = true
            continue
        end
        tracked = get(state.threads, sched.thread_ts, nothing)
        ch = tracked === nothing ? state.config.slack_channel_id : tracked.channel_id
        # Resume the thread's current session: the saved id can be older (the
        # thread moved to a fresh session after the follow-up was scheduled).
        # The saved id is used only when the thread is no longer tracked.
        sid = tracked === nothing ? sched.session_id : tracked.session_id
        prompt = isempty(sid) ? REVIVED_THREAD_NOTE * "\n" * sched.prompt : sched.prompt
        # The notice is posted inside the run, before Claude starts; its Slack ts
        # is the cursor if the thread has to be tracked again
        started = run_agent_loop!(state, sched.thread_ts, prompt, sid; channel_id=ch,
            before_run = () -> slack_post_message(state.config, "_Scheduled follow-up firing..._";
                                                  thread_ts=sched.thread_ts, channel_id=ch))
        started || continue
        filter!(s -> s !== sched, state.scheduled)
        push!(fired, sched)
    end
    # Saved on every poll while a follow-up waits, not only the first: a save
    # that failed once must not leave the deferral unsaved
    (waiting || !isempty(fired)) || return
    try
        save_state!(state)
    catch e
        @error "SlackClaw: state save failed" exception=(e, catch_backtrace())
    end
    for sched in fired
        @info "SlackClaw: fired scheduled task for thread $(sched.thread_ts)"
    end
end

# --- Proactive mode ---

const PROACTIVE_LOG_FILE = ".slackclaw_proactive_log"
const PROACTIVE_TASKS_FILE = ".slackclaw_proactive_tasks"

const PROACTIVE_PREFIX = """You are running a proactive check. \
If nothing is worth posting, respond with exactly "$(SKIP_TOKEN)" and nothing else. \
Only post if you have something genuinely useful or interesting.

Read the proactive tasks file at "%TASKS_PATH%" for your current task suggestions. \
Read the proactive log file at "%LOG_PATH%" to see what you have posted recently. \
Do not repeat or re-report things already in the log. \
If you do post something, keep it concise.

"""

"""
    append_proactive_log(log_path, text; suppressed=false)

Append one flattened line to the proactive log. Posted entries are truncated to
a one-liner; suppressed entries keep the FULL text — the next cycle's dedup
reads this log, and a suppressed run's reasoning is its only trace
(suppressed != lost). Errors are swallowed: the log is best-effort and must
never take down the proactive task.
"""
function append_proactive_log(log_path::String, text::AbstractString; suppressed::Bool=false)
    try
        ts_str = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
        entry = replace(suppressed ? text : first(text, 200), '\n' => ' ')
        tag = suppressed ? " [suppressed]" : ""
        open(log_path, "a") do io
            println(io, "[$ts_str]$tag $entry")
        end
    catch; end
end

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
            if !result.success || isempty(response_text)
                @info "SlackClaw: proactive check — nothing to report"
                return
            end
            if is_decline(response_text)
                # Narrated decline: suppress the post, but preserve any
                # reasoning around the token for the next cycle's dedup
                response_text != SKIP_TOKEN &&
                    append_proactive_log(log_path, response_text; suppressed=true)
                @info "SlackClaw: proactive check — declined ($(SKIP_TOKEN))"
                return
            end

            # Post as new top-level message in primary channel
            thread_ts = slack_post_message(config, response_text; channel_id=primary)

            append_proactive_log(log_path, response_text)

            # Track thread for follow-up replies
            if !isempty(result.session_id)
                track_thread!(state, thread_ts, primary; session_id=result.session_id)
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
    track_thread!(state, thread_ts, channel_id; session_id="", attempted="", session_missing=false,
                  cursor=thread_ts) -> String

Record a finished run in `thread_ts` and save state; returns the session id the
thread now holds (empty: nothing to resume, so the next reply starts a fresh
session with [`REVIVED_THREAD_NOTE`](@ref) in its prompt).

- `session_id` non-empty (the run printed one): the thread holds it.
- Otherwise (a failed run with no id): a tracked thread keeps the id it holds,
  which may be newer than the one this run `attempted` to resume (a scheduled
  task fires with the id it was saved with); an untracked thread starts with
  `attempted`. With `session_missing` (the CLI refused to resume `attempted`) that
  id is dropped, but only where the thread still holds it.

A tracked thread's `ThreadSession` is updated in place under `dispatch_lock`, never
replaced: a poll or socket claim holding the object keeps claiming against the
live cursor, and a tracked thread keeps the last reply it claimed, so a reply
posted while the run was finishing is still read. An untracked thread starts at
`cursor`, always a Slack timestamp: its parent `thread_ts` for a thread that is
new (a just-posted message, so no reply in it has been read), or the message a
run answered. The host clock is never used. With `cursor = ""` (the caller knows
no such boundary) an untracked thread is not tracked at all: reading it from a
guessed point could run handled replies again or skip unread ones.
A failed state save is logged, never thrown: it must not replace the run's reply.
"""
function track_thread!(state::MonitorState, thread_ts::AbstractString, channel_id::AbstractString;
                       session_id::AbstractString="", attempted::AbstractString="",
                       session_missing::Bool=false, cursor::AbstractString=thread_ts)
    held = lock(state.dispatch_lock) do
        s = get(state.threads, thread_ts, nothing)
        if s === nothing
            sid = !isempty(session_id) ? session_id : session_missing ? "" : attempted
            isempty(cursor) && return (String(sid), false)
            state.threads[thread_ts] = ThreadSession(
                String(thread_ts), String(sid), String(cursor), time(), String(channel_id))
            return (String(sid), true)
        end
        if !isempty(session_id)
            s.session_id = String(session_id)
        elseif session_missing && s.session_id == attempted
            s.session_id = ""
        end
        s.created = time()  # recent activity: the thread is not the oldest for the cap
        return (s.session_id, true)
    end
    sid, changed = held
    changed || return sid
    try
        save_state!(state)
    catch e
        @error "SlackClaw: state save failed" thread_ts exception=(e, catch_backtrace())
    end
    return sid
end

"""Line ending a failed run's reply when the next run resumes its session."""
const FAILED_RUN_CONTINUE_LINE = "_Reply in this thread to continue; the next run resumes this one._"

"""Line ending a failed run's reply when there is no session to resume."""
const FAILED_RUN_RETRY_LINE = "_Reply in this thread to try again; this run kept no context, so include the request._"

"""
    failure_reply(reason, session_id) -> String

Thread text for a failed run: the reason, then a line saying that a reply in the
thread starts the next run. The line says the run continues only when there is a
session to resume. A long reason (an error result's whole text) is cut to 3000
characters, so the line is never lost to the post's chunk limit.
"""
function failure_reply(reason::AbstractString, session_id::AbstractString)
    reason = length(reason) > 3000 ? first(reason, 3000) * " …" : reason
    return string(reason, "\n\n", isempty(session_id) ? FAILED_RUN_RETRY_LINE : FAILED_RUN_CONTINUE_LINE)
end

"""Tell a message in a busy thread that the thread's run is still going (and
for how long); the message itself starts no run."""
function post_still_working(state::MonitorState, thread_ts::AbstractString,
                            channel_id::AbstractString)
    elapsed = round(Int, time() - get(state.busy_threads, thread_ts, time()))
    mins, secs = divrem(elapsed, 60)
    elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
    slack_post_message(state.config, "_Still working... ($(elapsed_str) elapsed)_";
                       thread_ts, channel_id)
end

"""Add a reaction, logging instead of throwing: on a failure path a lost reaction
must not cost the post that tells the user what happened."""
function react_quietly(config::SlackClawConfig, ts::AbstractString, emoji::AbstractString;
                       channel_id::AbstractString=config.slack_channel_id)
    isempty(ts) && return nothing
    try
        slack_add_reaction(config, ts, emoji; channel_id)
    catch e
        @error "SlackClaw: reaction failed" ts emoji exception=(e, catch_backtrace())
    end
    return nothing
end

"""Clear the thread's busy mark only if it is still `mark` (this run's): a run
that released it early must not clear the mark of a newer run in the thread."""
release_busy!(state::MonitorState, thread_ts::AbstractString, mark::Float64) =
    get(state.busy_threads, thread_ts, nothing) === mark && delete!(state.busy_threads, thread_ts)

"""
    run_agent_loop!(state, thread_ts, prompt, session_id; react_ts="", channel_id=state.config.slack_channel_id)

Run Claude in a loop, handling [CONTINUE] and [SCHEDULE] directives.
Posts each response to the thread. Watches status file during execution.
User-message callers pass `prompt` already sender-attributed
([`attribute_sender`](@ref)); scheduled/directive prompts are not user
messages and arrive bare. Returns `true` when the run started, `false` when it
was turned away: the thread already has a run (one run per thread, whatever
dispatched it: the message gets "Still working"), or every task slot is taken.

The check and the busy mark are one step with no yield in between.
`before_run` (the dispatcher's first Slack call: the 👀 reaction, the
follow-up notice) runs inside the task before Claude starts, so it is ordered
before anything the run posts, and its failure is logged, never fatal. When it
returns a Slack ts (a posted notice), that ts is the reply cursor should the run
have to track the thread again.
"""
function run_agent_loop!(state::MonitorState, thread_ts::String, prompt::String,
                         session_id::String; react_ts::String="",
                         channel_id::String=state.config.slack_channel_id,
                         before_run=nothing)
    config = state.config
    filter!(!istaskdone, state.active_tasks)

    if haskey(state.busy_threads, thread_ts)
        post_still_working(state, thread_ts, channel_id)
        return false
    end
    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config, "Busy — reply in this thread with the request to try again."; thread_ts, channel_id)
        return false
    end

    busy_mark = time()
    state.busy_threads[thread_ts] = busy_mark

    task = @async begin
        current_prompt = prompt
        current_session = session_id
        continue_count = 0
        reran_missing = false
        # A thread this run has to track (it was untracked) starts after the
        # message being answered, else after the run's own notice (set below):
        # both Slack timestamps. With neither, the run does not track it.
        new_cursor = react_ts

        # Ends this run's hold on the thread once: releases the busy mark, then
        # clears the status file. A failed run calls it before posting its
        # reason, so a reply meanwhile can start a run that this run no longer
        # touches. A cleanup error is logged.
        released = false
        function finish_run!()
            released && return
            released = true
            release_busy!(state, thread_ts, busy_mark)
            try
                status_path = joinpath(config.repo_dir, config.status_file)
                isfile(status_path) && rm(status_path; force=true)
            catch e
                @error "SlackClaw: status file cleanup failed" thread_ts exception=(e, catch_backtrace())
            end
        end

        try
            # Inside the try: nothing after the busy mark can skip its release
            if before_run !== nothing
                try
                    r = before_run()
                    isempty(new_cursor) && r isa AbstractString && (new_cursor = String(r))
                catch e
                    @error "SlackClaw: dispatch notice failed" thread_ts exception=(e, catch_backtrace())
                end
            end
            while true
                # Start status file watcher
                stop_watcher = Ref(false)
                watcher = @async watch_status_file(config, thread_ts, stop_watcher; channel_id)

                # Run Claude (pass thread context for file upload support)
                result = try
                    run_claude(current_prompt, config;
                        session_id=current_session,
                        thread_ts=thread_ts,
                        channel_id=channel_id)
                finally
                    stop_watcher[] = true
                end

                # The CLI has no such session (its transcripts moved or were
                # removed): drop the id and run this message again at once, so a
                # stale id never costs the user a reply. The rerun resumes the
                # thread's own session when it holds a different one (a scheduled
                # task fires with the id it was saved with), else starts fresh
                # with REVIVED_THREAD_NOTE. Once per dispatched message, its
                # [CONTINUE] steps included.
                if result.session_missing && !reran_missing
                    reran_missing = true
                    held = track_thread!(state, thread_ts, channel_id;
                        attempted=current_session, session_missing=true, cursor=new_cursor)
                    @info "SlackClaw: session not found, running again" thread_ts refused=current_session resume=held
                    isempty(held) && (current_prompt = REVIVED_THREAD_NOTE * "\n" * current_prompt)
                    current_session = held
                    continue
                end

                # Update session tracking after every run. A failed run keeps its
                # thread tracked even with no session id (a timeout, or a failure
                # that printed none): the reconcile poll then reads replies in the
                # thread, so a reply starts a new run with or without a socket
                # event. A session the CLI refused to resume is dropped.
                current_session = track_thread!(state, thread_ts, channel_id;
                    session_id=result.session_id, attempted=current_session,
                    session_missing=result.session_missing, cursor=new_cursor)

                if !result.success
                    # The reply invites an immediate answer, so the run lets go
                    # of the thread before it is posted: a reply that arrives
                    # while the post is in flight starts a run instead of "Still
                    # working". A failed reaction must not cost the post, and a
                    # failed post is only logged: the run's bookkeeping is done,
                    # and a newer run may own the thread by then.
                    react_quietly(config, react_ts, "x"; channel_id)
                    finish_run!()
                    try
                        post_response(config, failure_reply(result.result_text, current_session),
                                      thread_ts; channel_id)
                    catch e
                        @error "SlackClaw: failure reply not posted" thread_ts exception=(e, catch_backtrace())
                    end
                    break
                end

                # Parse directives
                directive, clean_text = if config.agent_directives
                    parse_directives(result.result_text)
                else
                    (DIRECTIVE_DONE, result.result_text)
                end

                # Post the clean response (directive-only messages leave clean_text empty).
                # The skip gate sits here, AFTER the session bookkeeping above — a skipped
                # message must still update thread state so later replies keep continuity.
                skipped = should_skip_response(clean_text, config.allow_skip)
                if skipped
                    @info "SlackClaw: primary message skipped by $(SKIP_TOKEN)" thread_ts channel_id
                    # Eyes-as-intent: take back the dispatch-time "seen" mark —
                    # lingering eyes would promise a reply that never comes;
                    # their removal signals "saw it, deliberately staying out"
                    !isempty(react_ts) && slack_reactions_remove(config, react_ts, "eyes"; channel_id)
                elseif !isempty(strip(clean_text))
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
                    # The follow-up is queued: a failed save or confirmation is
                    # logged, never an error reply inviting a retry (which would
                    # queue it twice)
                    try
                        save_state!(state)
                        mins = round(Int, directive.delay_s / 60)
                        slack_post_message(config,
                            "_Scheduled follow-up in $(mins)m._";
                            thread_ts, channel_id)
                    catch e
                        @error "SlackClaw: follow-up queued, but its save or notice failed" thread_ts exception=(e, catch_backtrace())
                    end
                    @info "SlackClaw: [SCHEDULE] $(directive.delay_s)s for thread $thread_ts"
                    break

                else  # :done
                    # No checkmark on a deliberately skipped message — it would itself be noise
                    # Best effort: the answer is posted, so a failed reaction
                    # must not turn into an error reply inviting a retry
                    !skipped && react_quietly(config, react_ts, "white_check_mark"; channel_id)
                    break
                end
            end
        catch e
            @error "SlackClaw agent loop error" exception=(e, catch_backtrace())
            # Once the run has let go of the thread it records nothing more
            if !released
                try
                    # Same as a failed run: the thread stays reachable by a reply
                    current_session = track_thread!(state, thread_ts, channel_id;
                                                    attempted=current_session, cursor=new_cursor)
                    err_msg = e isa Exception ? string(typeof(e).name.name) : "Unknown error"
                    react_quietly(config, react_ts, "x"; channel_id)
                    finish_run!()
                    slack_post_message(config,
                        failure_reply("Error: $err_msg (check server logs)", current_session);
                        thread_ts, channel_id)
                catch e2
                    @error "SlackClaw: error reply not posted" thread_ts exception=(e2, catch_backtrace())
                end
            end
        finally
            finish_run!()
        end
    end

    push!(state.active_tasks, task)
    return true
end

# --- Dispatch: top-level messages ---

function dispatch_command!(state::MonitorState, msg::SlackMessage;
                          channel_id::String=state.config.slack_channel_id)
    config = state.config

    # Dynamic proactive frequency adjustment. Matched against the caption only:
    # a file named "proactive off.txt" must not toggle anything.
    caption = caption_of(msg.text)
    m = match(r"proactive\s+(?:every|interval)\s+(\d+[hm]\w*)"i, caption)
    if m !== nothing
        new_interval = parse_duration(String(m.captures[1]))
        config.proactive_interval_s = new_interval
        mins = div(new_interval, 60)
        slack_post_message(config, "_Proactive interval set to $(mins)m._";
            thread_ts=msg.ts, channel_id)
        return
    end
    m = match(r"proactive\s+(on|off)"i, caption)
    if m !== nothing
        config.proactive_enabled = lowercase(m.captures[1]) == "on"
        status = config.proactive_enabled ? "enabled" : "disabled"
        slack_post_message(config, "_Proactive mode $(status)._";
            thread_ts=msg.ts, channel_id)
        return
    end

    filter!(!istaskdone, state.active_tasks)

    # The message's own thread already has a run: a reply in it arrived first
    # (this message reached us late, by reconciliation) and revived the thread.
    # One run per thread, so this one does not run, and says so plainly rather
    # than "Still working", which would read as if it were being handled.
    # Checked before the slot limit, so the user gets the resend instruction.
    if haskey(state.busy_threads, msg.ts)
        slack_post_message(config,
            "_This thread already has a run going, so this message was not run. " *
            "Reply in this thread with the request when it finishes._";
            thread_ts=msg.ts, channel_id)
        return
    end

    if length(state.active_tasks) >= config.max_concurrent_tasks
        slack_post_message(config,
            "Busy with $(length(state.active_tasks)) task(s) — please wait.";
            thread_ts=msg.ts, channel_id)
        return
    end

    # Eyes-as-intent: eyes go on at dispatch on ALL channels — on allow_skip
    # channels the skip branch of run_agent_loop! takes them back OFF when the
    # reply is [SKIP]. Lingering eyes = reply coming; vanished eyes = seen,
    # deliberately staying out. The reaction goes on inside the run, before
    # Claude starts. The run tracks the thread when it ends, whatever the
    # outcome, with its cursor at this message, so a reply posted during the run
    # is read afterwards by the reconcile poll.
    #
    # A message whose thread is already tracked reached us late (a reply in its
    # thread was delivered and ran first, e.g. under a `me_message` the socket
    # skips): it resumes the thread's session rather than starting one, so the
    # thread keeps one conversation (a follow-up the reply scheduled resumes it).
    # The prompt says the message is older than the replies already handled, so
    # a later correction in a reply is not read as overridden by it.
    tracked = get(state.threads, msg.ts, nothing)
    sid = tracked === nothing ? "" : tracked.session_id
    prompt = (isempty(sid) ? "" : LATE_PARENT_NOTE * "\n") * attribute_sender(msg.text, msg.user)
    run_agent_loop!(state, msg.ts, prompt, sid;
                    react_ts=msg.ts, channel_id,
                    before_run = () -> slack_add_reaction(config, msg.ts, "eyes"; channel_id))
end

"""
Prepended to a top-level message that reaches the monitor after a reply in its
thread already ran, when it resumes that thread's session: the message is the
thread's original post, older than the replies already in the session, so a
later reply (a correction, a new instruction) takes precedence over it.
"""
const LATE_PARENT_NOTE = """
[note from the dispatcher: the message below is this Slack thread's original top-level \
post. It reached you late: it was posted BEFORE the replies in this thread that you have \
already handled. Where it conflicts with those replies, the replies are the more recent \
instructions.]"""

# --- Dispatch: thread replies ---

"""
Prepended to the prompt when dispatching into a thread with no Claude session to
resume (empty `session_id`): a revived expired thread, or a thread whose earlier
run failed without a session id. The Slack thread looks continuous to the user,
but the earlier context is gone. The note makes Claude disclose that only when
the message actually depends on the missing context — an unconditional "context
expired" reply would be the same bookkeeping noise the silent-expiry change
removed.
"""
const REVIVED_THREAD_NOTE = """
[note from the dispatcher: the earlier conversation in this Slack thread is NOT \
available to you (the thread expired, an earlier run in it failed before its \
session could be resumed, or its first message has not reached you yet). If the message relies on that earlier content, say the \
earlier context is not available and ask the user to restate what you need; do not \
guess. If the message stands on its own, just answer it and do not mention this.]"""

"""Prompt for a thread dispatch: sender-attributed text, with
[`REVIVED_THREAD_NOTE`](@ref) prepended when the session has no Claude context
to resume."""
thread_prompt(session::ThreadSession, msg::SlackMessage) =
    (isempty(session.session_id) ? REVIVED_THREAD_NOTE * "\n" : "") *
    attribute_sender(msg.text, msg.user)

function dispatch_thread_reply!(state::MonitorState, msg::SlackMessage, session::ThreadSession)
    config = state.config
    ch = session.channel_id

    # Same eyes-as-intent contract as dispatch_command! — a [SKIP]ped thread
    # reply gets its eyes removed in the agent loop's skip branch. The reaction
    # goes on inside the run, before Claude starts. A busy thread gets "Still
    # working" from run_agent_loop! (one run per thread).
    run_agent_loop!(state, session.thread_ts, thread_prompt(session, msg),
                    session.session_id; react_ts=msg.ts, channel_id=ch,
                    before_run = () -> slack_add_reaction(config, msg.ts, "eyes"; channel_id=ch))
end

# --- Shutdown ---

"""
    stop_monitor!(state::MonitorState)

Stop the monitor: flips `state.running` (loops and background tasks exit at
their next check), waits for in-flight dispatch tasks, and posts a shutdown
notice to the primary channel.
"""
function stop_monitor!(state::MonitorState)
    @info "SlackClaw: stopping monitor..."
    state.running = false
    for t in state.active_tasks
        try wait(t) catch; end
    end
    empty!(state.active_tasks)
    # Same gate as the startup banner: `run_monitor`'s `finally` reaches here on
    # crashes too, so an ungated notice spams the channel on every supervised
    # (systemd Restart=) crash-loop cycle exactly like the startup banner would.
    if state.config.announce_startup
        try
            slack_post_message(state.config, "_SlackClaw monitor stopped._")
        catch; end
    end
    @info "SlackClaw: stopped."
    return nothing
end
