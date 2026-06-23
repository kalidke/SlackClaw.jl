"""
Result from a Claude CLI invocation.
"""
struct ClaudeResult
    success::Bool
    result_text::String
    duration_ms::Int
    cost_usd::Float64
    session_id::String
end

"""
Appended to the system prompt when the upload helper and a Slack thread are
available, so Claude knows it can post files/images back to the thread.
"""
const UPLOAD_INSTRUCTIONS = """
To send a file or image back to Slack (for example a plot you generated), run the \
uploader at the \$SLACKCLAW_UPLOAD environment variable: \
`\$SLACKCLAW_UPLOAD <file_path> ["caption"]`. It attaches the file to the current \
thread. Save the figure to a file first, then upload it.
"""

"""
    run_claude(prompt::String, config::SlackClawConfig) -> ClaudeResult

Run `claude` CLI in `--print` mode with JSON output. Blocks until complete or timeout.
"""
function run_claude(prompt::String, config::SlackClawConfig;
                    session_id::String="",
                    thread_ts::String="",
                    channel_id::String="")
    args = String[
        "claude", "-p", prompt,
        "--print",
        "--output-format", "json",
        "--dangerously-skip-permissions",
        "--max-turns", string(config.max_turns),
    ]

    if !isempty(session_id)
        push!(args, "--resume", session_id)
    end

    # Upload helper availability: needs the script plus a thread to post into.
    upload_bin = normpath(joinpath(@__DIR__, "..", "bin", "slack-upload"))
    can_upload = isfile(upload_bin) && !isempty(thread_ts) &&
                 !isempty(channel_id) && !isempty(config.slack_bot_token)

    # Build system prompt: user config + directives + upload helper
    sys_parts = String[]
    !isempty(config.system_prompt) && push!(sys_parts, config.system_prompt)
    config.agent_directives && push!(sys_parts, DIRECTIVE_INSTRUCTIONS)
    can_upload && push!(sys_parts, UPLOAD_INSTRUCTIONS)
    if !isempty(sys_parts)
        push!(args, "--system-prompt", join(sys_parts, "\n\n"))
    end

    if config.max_budget_usd > 0
        push!(args, "--max-budget-usd", string(config.max_budget_usd))
    end

    if !isempty(config.model)
        push!(args, "--model", config.model)
    end

    for tool in config.allowed_tools
        push!(args, "--allowedTools", tool)
    end

    # Build clean environment without Claude session vars
    filtered_env = String["$(k)=$(v)" for (k, v) in ENV if !startswith(k, "CLAUDE")]

    # Inject SlackClaw context so the upload helper can post into this thread.
    !isempty(thread_ts) && push!(filtered_env, "SLACKCLAW_THREAD_TS=$thread_ts")
    !isempty(channel_id) && push!(filtered_env, "SLACKCLAW_CHANNEL_ID=$channel_id")
    !isempty(config.slack_bot_token) && push!(filtered_env, "SLACKCLAW_BOT_TOKEN=$(config.slack_bot_token)")
    isfile(upload_bin) && push!(filtered_env, "SLACKCLAW_UPLOAD=$upload_bin")

    cmd = setenv(`$args`, filtered_env; dir=config.repo_dir)

    t_start = time()

    # Run with retry. A non-zero exit from `claude` is usually transient (rate
    # limit / overload / brief usage cap), so retry with exponential backoff
    # before giving up. stderr is captured (not discarded) so the real reason is
    # surfaced. We do NOT retry a timeout, nor a non-zero exit that already
    # produced stdout (it may have done partial work).
    res = _run_claude_once(cmd, config.claude_timeout_s)
    attempt = 0
    while !res.timed_out && res.exitcode != 0 && isempty(strip(res.stdout)) &&
          attempt < config.claude_max_retries
        attempt += 1
        backoff = config.claude_retry_backoff_s * 2.0^(attempt - 1)
        @warn "SlackClaw: claude exited non-zero — retrying" attempt exitcode=res.exitcode backoff_s=backoff stderr=last(strip(res.stderr), 300)
        sleep(backoff)
        res = _run_claude_once(cmd, config.claude_timeout_s)
    end

    duration_ms = round(Int, (time() - t_start) * 1000)

    if res.timed_out
        @warn "SlackClaw: claude timed out" timeout_s=config.claude_timeout_s
        return ClaudeResult(false, "Timed out after $(config.claude_timeout_s)s", duration_ms, 0.0, "")
    end

    if res.exitcode != 0
        reason = strip(res.stderr)
        msg = isempty(reason) ? "Claude exited non-zero (code $(res.exitcode))" :
              "Claude exited non-zero (code $(res.exitcode)): $(last(reason, 500))"
        @error "SlackClaw: claude dispatch failed" exitcode=res.exitcode stderr=reason
        return ClaudeResult(false, msg, duration_ms, 0.0, "")
    end

    return parse_claude_output(res.stdout, duration_ms)
end

"""
    _run_claude_once(cmd, timeout_s) -> NamedTuple

Run `cmd` once, capturing stdout and stderr separately and enforcing a hard
timeout (SIGTERM on overrun). Never throws on a non-zero exit; the caller
inspects `exitcode` / `stdout` / `stderr` / `timed_out`.
"""
function _run_claude_once(cmd::Base.AbstractCmd, timeout_s::Real)
    out = Pipe()
    err = Pipe()
    timed_out = false
    proc = try
        run(pipeline(ignorestatus(cmd), stdout=out, stderr=err); wait=false)
    catch e
        # Couldn't even spawn (e.g. `claude` not on PATH)
        return (exitcode = -1, stdout = "",
                stderr = "failed to spawn claude: $(sprint(showerror, e))", timed_out = false)
    end
    close(out.in)
    close(err.in)
    sout = @async read(out, String)
    serr = @async read(err, String)
    timer = Timer(timeout_s) do _
        if Base.process_running(proc)
            timed_out = true
            try; kill(proc); catch; end   # SIGTERM
        end
    end
    try
        wait(proc)
    finally
        close(timer)
    end
    return (exitcode = proc.exitcode, stdout = fetch(sout), stderr = fetch(serr), timed_out = timed_out)
end

"""
    parse_claude_output(output::String, duration_ms::Int) -> ClaudeResult

Parse JSON output from `claude --print --output-format json`.
The CLI returns a JSON array of event objects; the result is in the last
entry with `"type" => "result"`.
"""
function parse_claude_output(output::String, duration_ms::Int)
    try
        data = JSON.parse(output)
        # CLI returns a JSON array — find the result entry
        entry = if data isa Vector
            idx = findlast(d -> d isa Dict && get(d, "type", "") == "result", data)
            idx === nothing ? Dict() : data[idx]
        else
            data  # legacy single-object format
        end
        result_text = get(entry, "result", "")
        is_error = get(entry, "is_error", false)
        cost = get(entry, "total_cost_usd", 0.0)
        session_id = get(entry, "session_id", "")
        cli_duration = get(entry, "duration_ms", duration_ms)
        return ClaudeResult(!is_error, result_text, cli_duration, cost, session_id)
    catch
        # Not valid JSON -- treat raw output as the result
        return ClaudeResult(
            !startswith(output, "Error:"),
            output,
            duration_ms,
            0.0,
            "",
        )
    end
end
