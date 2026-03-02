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

    # Build system prompt: user config + directive instructions
    sys_parts = String[]
    !isempty(config.system_prompt) && push!(sys_parts, config.system_prompt)
    config.agent_directives && push!(sys_parts, DIRECTIVE_INSTRUCTIONS)
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

    # Inject SlackClaw context for file upload support
    if !isempty(thread_ts)
        push!(filtered_env, "SLACKCLAW_THREAD_TS=$thread_ts")
    end
    if !isempty(channel_id)
        push!(filtered_env, "SLACKCLAW_CHANNEL_ID=$channel_id")
    end
    if !isempty(config.slack_bot_token)
        push!(filtered_env, "SLACKCLAW_BOT_TOKEN=$(config.slack_bot_token)")
    end
    # Path to the upload helper script (sibling to this package's src/)
    upload_bin = normpath(joinpath(@__DIR__, "..", "bin", "slack-upload"))
    if isfile(upload_bin)
        push!(filtered_env, "SLACKCLAW_UPLOAD=$upload_bin")
    end

    cmd = setenv(`$args`, filtered_env; dir=config.repo_dir)

    t_start = time()
    output = ""
    timed_out = false

    task = @async try
        read(cmd, String)
    catch e
        if e isa ProcessFailedException
            "Process failed (exit code non-zero)"
        else
            rethrow()
        end
    end

    # Wait with timeout
    timer = Timer(config.claude_timeout_s)
    @async begin
        wait(timer)
        if !istaskdone(task)
            timed_out = true
            # Kill the process group -- schedule_kill triggers SIGTERM
            try
                Base.throwto(task, InterruptException())
            catch; end
        end
    end

    try
        output = fetch(task)
    catch e
        output = "Error: $e"
    finally
        close(timer)
    end

    duration_ms = round(Int, (time() - t_start) * 1000)

    if timed_out
        return ClaudeResult(false, "Timed out after $(config.claude_timeout_s)s", duration_ms, 0.0, "")
    end

    return parse_claude_output(output, duration_ms)
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
