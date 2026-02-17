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
function run_claude(prompt::String, config::SlackClawConfig; session_id::String="")
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

    if !isempty(config.system_prompt)
        push!(args, "--system-prompt", config.system_prompt)
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
"""
function parse_claude_output(output::String, duration_ms::Int)
    try
        data = JSON.parse(output)
        result_text = get(data, "result", "")
        is_error = get(data, "is_error", false)
        cost = get(data, "total_cost_usd", 0.0)
        session_id = get(data, "session_id", "")
        # duration_ms from CLI if available, else use our measurement
        cli_duration = get(data, "duration_ms", duration_ms)
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
