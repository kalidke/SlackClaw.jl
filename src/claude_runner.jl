"""
Result from a Claude CLI invocation.

`session_missing` is true only when the run asked to `--resume` a session and the
CLI refused it as unknown (see [`resume_refused`](@ref)); the five-argument
constructor sets it false.
"""
struct ClaudeResult
    success::Bool
    result_text::String
    duration_ms::Int
    cost_usd::Float64
    session_id::String
    session_missing::Bool
end

ClaudeResult(success, result_text, duration_ms, cost_usd, session_id) =
    ClaudeResult(success, result_text, duration_ms, cost_usd, session_id, false)

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
    resolve_self_mentions(text, bot_user_id) -> String

Rewrite Slack mentions of the bot itself (`<@U…>`) to `@you`. Slack delivers
mentions as raw member IDs, which carry no meaning for Claude — it cannot tell
that IT was tagged, which is the basis for deciding whether a message is
addressed to it (e.g. the `allow_skip` teammate behavior). Other users' IDs are
left untouched (resolving them needs `users.info` + the `users:read` scope).
"""
resolve_self_mentions(text::AbstractString, bot_user_id::AbstractString) =
    isempty(bot_user_id) ? String(text) : replace(text, "<@$(bot_user_id)>" => "@you")

"""`CLAUDE_CODE_`-prefixed vars exempt from the nested-session strip in [`filtered_child_env`](@ref)."""
const CHILD_ENV_PASSTHROUGH = ("CLAUDE_CODE_OAUTH_TOKEN",)

"""
Variables the `claude` child inherits by exact name (see [`filtered_child_env`](@ref)):
what a shell, git, `gh`, the CLI and its HTTP client need, the child's own
Anthropic credential and endpoint, and the names (not the secrets) of a cloud
provider profile or region. Nothing that carries a credential of the monitor's:
an Anthropic admin key, a `GH_TOKEN` or a cloud secret key passes only when the
channel names it in `child_env_passthrough`.
"""
const CHILD_ENV_NAMES = (
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LANGUAGE", "TERM", "TZ",
    # the CLI's own login after `claude setup-token` (a secret-looking name, so by exact name)
    "CLAUDE_CODE_OAUTH_TOKEN",
    "TMPDIR", "TMP", "TEMP", "SSH_AUTH_SOCK", "DBUS_SESSION_BUS_ADDRESS",
    # proxies (one whose URL carries a user name or password: see filtered_child_env)
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
    "http_proxy", "https_proxy", "no_proxy", "all_proxy",
    # certificate trust, and Node's runtime options (e.g. --use-openssl-ca)
    "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "NODE_USE_SYSTEM_CA", "NODE_OPTIONS",
    "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO",
    # the Anthropic client: the child's own credential, endpoint and models
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
    "ANTHROPIC_VERTEX_PROJECT_ID", "ANTHROPIC_FOUNDRY_RESOURCE", "ANTHROPIC_FOUNDRY_BASE_URL",
    # cloud provider selectors (profile, region, file locations; not secret keys)
    "AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE",
    "CLOUD_ML_REGION", "GOOGLE_CLOUD_PROJECT", "GOOGLE_APPLICATION_CREDENTIALS",
    # git and gh identity and configuration
    "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
    "GIT_SSH_COMMAND", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT", "GH_CONFIG_DIR", "GH_REPO", "GH_HOST",
    # Claude Code settings it reads from the environment
    "DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "BASH_DEFAULT_TIMEOUT_MS",
    "BASH_MAX_TIMEOUT_MS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT", "MAX_THINKING_TOKENS",
    # host policy: GPUs and thread counts, the library path, a display
    "CUDA_VISIBLE_DEVICES", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
    "LD_LIBRARY_PATH", "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
    # npm's cache location (not the npm_config_ prefix, which can carry registry tokens)
    "npm_config_cache", "NPM_CONFIG_CACHE",
)

"""
Variables the `claude` child inherits by prefix (see [`filtered_child_env`](@ref)):
locale, XDG base directories, Julia and juliaup (the depot), and Claude Code
configuration such as `CLAUDE_CONFIG_DIR` (less the nested-session vars).
"""
const CHILD_ENV_PREFIXES = ("LC_", "XDG_", "JULIA_", "JULIAUP_", "CLAUDE_")

"""
The variables [`run_claude`](@ref) sets for each run. They are never inherited
from the monitor, even when `child_env_passthrough` names them.
"""
const SLACKCLAW_RUN_VARS = ("SLACKCLAW_THREAD_TS", "SLACKCLAW_CHANNEL_ID", "SLACKCLAW_BOT_TOKEN",
                            "SLACKCLAW_UPLOAD", "SLACKCLAW_STATUS")

"""The proxy variables: a user name or password in one counts with or without a URL scheme (`user:pass@host:port`)."""
const PROXY_NAMES = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")

"""
True when `v` holds a Slack credential anywhere in it (alone, in an
`Authorization` header, in a URL), recognized by its shape:
- a token: `xoxb-` bot, `xoxp-` user and the other `xox?-` kinds, and `xapp-`
  app-level, each as `<kind>-<digits>-<letter or digit>`, so a path such as
  `/opt/xapp-tools` or `/opt/xapp-1.2` is not one (a rotating `xoxe.xoxp-…`
  holds one); a workflow `xwfp-<digit>`;
- a session cookie `xoxd-…`, which may go on with a letter;
- an incoming-webhook URL (`hooks.slack.com` or GovSlack's
  `hooks.slack-gov.com`, any letter case, any port).
"""
has_slack_credential(v::AbstractString) =
    occursin(r"(?<![A-Za-z0-9])(xox[a-z]-[0-9]+-[0-9A-Za-z]|xoxd-[0-9A-Za-z%+/]|xapp-[0-9]+-[0-9A-Za-z]|xwfp-[0-9])|(?i:hooks\.slack(?:-gov)?\.com)(?::[0-9]+)?/", v)

"""
True when `v`, the value of variable `k`, holds a URL with a user name or
password (`scheme://user:pass@host`; for a proxy variable also `user:pass@host`
with no scheme).
"""
has_url_credential(k::AbstractString, v::AbstractString) =
    occursin(r"://[^/\s@]+@", v) || (k in PROXY_NAMES && occursin(r"^\s*[^/\s@]+@", v))

"""
True for a name that looks like it holds a secret (containing `TOKEN`,
`SECRET`, `PASSW`, `KEY`, `CREDENTIAL`, `WEBHOOK`, `COOKIE`, or the word `PAT`,
any case). No prefix in [`CHILD_ENV_PREFIXES`](@ref) passes such a name (a
usage monitor's `CLAUDE_SESSION_KEY`, say); it passes only by exact name.
"""
secret_name(k::AbstractString) =
    occursin(r"TOKEN|SECRET|PASSW|KEY|CREDENTIAL|WEBHOOK|COOKIE|(^|_)PAT($|_)"i, k)

"""
    filtered_child_env(env, passthrough=()) -> Vector{String}

Build the environment the `claude` subprocess inherits from the monitor: an
allow list, not the monitor's whole environment, since the child runs prompts
any channel member can write and a fleet's environment holds every workspace's
Slack tokens and other credentials (issue #11). A variable passes when its name
is in [`CHILD_ENV_NAMES`](@ref), starts with one of
[`CHILD_ENV_PREFIXES`](@ref), or is named in `passthrough`
(`config.child_env_passthrough`: exact names; an entry ending in `*` is not a
prefix, and is logged once and ignored).

Exceptions:
- **Nested-session detection vars.** `CLAUDECODE` and `CLAUDE_CODE_*` are
  dropped, except the credentials in [`CHILD_ENV_PASSTHROUGH`](@ref):
  `CLAUDE_CODE_OAUTH_TOKEN` is the child's only auth path after
  `claude setup-token`, which prints the token without storing it. Other
  `CLAUDE_*` vars are user configuration and pass: stripping
  `CLAUDE_CONFIG_DIR` sends every child's transcripts back to `~/.claude`.
- **Slack credentials.** A variable whose value holds one
  ([`has_slack_credential`](@ref)) never passes, even when `passthrough` names it.
- **A URL with a user name or password** ([`has_url_credential`](@ref)), such
  as a proxy with its password, passes only when `passthrough` names the
  variable, not through the allow list or a prefix.
- **A secret-looking name** ([`secret_name`](@ref)) never passes through one of
  [`CHILD_ENV_PREFIXES`](@ref); it passes only by exact name
  (`CLAUDE_CODE_OAUTH_TOKEN` is in [`CHILD_ENV_NAMES`](@ref) for that reason).
- **[`SLACKCLAW_RUN_VARS`](@ref)** are never inherited: [`run_claude`](@ref) sets
  them for each run. Other `SLACKCLAW_*` names pass only through `passthrough`.
"""
function filtered_child_env(env, passthrough=())
    names = String[p for p in passthrough if !endswith(p, "*")]
    for p in passthrough
        endswith(p, "*") && warn_prefix_entry(p)
    end
    listed(k) = k in CHILD_ENV_NAMES || (any(p -> startswith(k, p), CHILD_ENV_PREFIXES) && !secret_name(k))
    nested(k) = k == "CLAUDECODE" || (startswith(k, "CLAUDE_CODE_") && !(k in CHILD_ENV_PASSTHROUGH))
    out = String[]
    for (k, v) in env
        (k in SLACKCLAW_RUN_VARS || nested(k)) && continue
        named = k in names
        (named || listed(k)) || continue
        # A variable dropped for its value alone is named in the log once, so a
        # dropped PATH or proxy is visible; its value never is
        if has_slack_credential(v)
            warn_dropped(k, "holds a Slack token or webhook URL, which never passes")
        elseif !named && has_url_credential(k, v)
            warn_dropped(k, "is a URL with a user name or password; name it exactly in child_env_passthrough to pass it")
        else
            push!(out, "$(k)=$(v)")
        end
    end
    return out
end

"""What [`warn_dropped`](@ref) has logged, so each is logged once per process."""
const WARNED_DROPPED = Set{String}()

"""Log once per process that variable `k` is not passed to Claude runs, and why (never its value)."""
warn_dropped(k::AbstractString, why::AbstractString) =
    warn_once(k, "SlackClaw: not passing $k to Claude runs: its value $why")

"""
Log once per process that a `child_env_passthrough` entry ending in `*` is
ignored. The entry is echoed only when it is a variable name and a `*`, so a
value pasted into the list never reaches the log.
"""
warn_prefix_entry(p::AbstractString) =
    warn_once("entry " * p, "SlackClaw: child_env_passthrough takes exact names; ignoring " *
              (occursin(r"^[A-Za-z_][A-Za-z0-9_]*\*$", p) ? "the entry $p" : "an entry ending in *"))

function warn_once(key::AbstractString, msg::AbstractString)
    key in WARNED_DROPPED && return
    push!(WARNED_DROPPED, String(key))
    @warn msg
end

"""
    run_claude(prompt::String, config::SlackClawConfig) -> ClaudeResult

Run `claude` CLI in `--print` mode with JSON output. Blocks until complete or timeout.
Permissions are governed by `--permission-mode \$(config.permission_mode)` (default
`"auto"`, the classifier mode); a denial returns promptly as an `is_error` result
rather than hanging the dispatch. Mentions of the bot itself in the prompt are
rewritten to `@you` ([`resolve_self_mentions`](@ref)).

The child inherits only the allow-listed environment ([`filtered_child_env`](@ref)),
plus `SLACKCLAW_THREAD_TS`, `SLACKCLAW_CHANNEL_ID`, `SLACKCLAW_BOT_TOKEN` and
`SLACKCLAW_UPLOAD` for the upload helper, and `SLACKCLAW_STATUS` when
`status_path` is given: the run's own status file ([`run_status_path`](@ref)).
"""
function run_claude(prompt::String, config::SlackClawConfig;
                    session_id::String="",
                    thread_ts::String="",
                    channel_id::String="",
                    status_path::String="")
    prompt = resolve_self_mentions(prompt, config.bot_user_id)
    args = String[
        "claude", "-p", prompt,
        "--print",
        "--output-format", "json",
        "--permission-mode", config.permission_mode,
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

    # The allow-listed environment: no Slack token or other credential of the
    # monitor's is in the environment the child inherits (filtered_child_env).
    # The child is the monitor's OS user, so files and the monitor's own process
    # environment stay readable to it: this is not a sandbox.
    filtered_env = filtered_child_env(ENV, config.child_env_passthrough)

    # Inject SlackClaw context so the upload helper can post into this thread,
    # and this run's own status file
    !isempty(thread_ts) && push!(filtered_env, "SLACKCLAW_THREAD_TS=$thread_ts")
    !isempty(channel_id) && push!(filtered_env, "SLACKCLAW_CHANNEL_ID=$channel_id")
    !isempty(config.slack_bot_token) && push!(filtered_env, "SLACKCLAW_BOT_TOKEN=$(config.slack_bot_token)")
    isfile(upload_bin) && push!(filtered_env, "SLACKCLAW_UPLOAD=$upload_bin")
    !isempty(status_path) && push!(filtered_env, "SLACKCLAW_STATUS=$status_path")

    cmd = setenv(`$args`, filtered_env; dir=config.repo_dir)

    t_start = time()

    # Run with retry. A non-zero exit from `claude` is usually transient (rate
    # limit / overload / brief usage cap), so retry with exponential backoff
    # before giving up. The failure reason is the stdout result text first, then
    # stderr as a fallback (see `exit_failure_message`). We do NOT retry a
    # timeout, nor a non-zero exit that already produced stdout (it may have done
    # partial work), nor a refused --resume (the session will not reappear).
    res = _run_claude_once(cmd, config.claude_timeout_s)
    attempt = 0
    while !res.timed_out && res.exitcode != 0 && isempty(strip(res.stdout)) &&
          !resume_refused(res, session_id) && attempt < config.claude_max_retries
        attempt += 1
        backoff = config.claude_retry_backoff_s * 2.0^(attempt - 1)
        @warn "SlackClaw: claude exited non-zero — retrying" attempt exitcode=res.exitcode backoff_s=backoff stderr=last(strip(res.stderr), 300)
        sleep(backoff)
        res = _run_claude_once(cmd, config.claude_timeout_s)
    end

    duration_ms = round(Int, (time() - t_start) * 1000)
    return interpret_claude_run(res, duration_ms, config.claude_timeout_s; resumed=session_id)
end

"""
    resume_refused(res, resumed) -> Bool

Whether a finished run is the CLI refusing `--resume` of the session `resumed`
(the id it was given; "" when it resumed nothing): it exited non-zero, printed
nothing on stdout, and printed `No conversation found with session ID: <that id>`
on stderr, as its own line (bare, or after "Error: "). Judged on the raw
streams, not the posted reason, so a result text that merely quotes the phrase
never counts, nor a line naming another id, nor a warning that quotes the refusal
inside other text.
"""
function resume_refused(res, resumed::AbstractString)
    isempty(resumed) && return false
    (res.timed_out || res.exitcode == 0 || !isempty(strip(res.stdout))) && return false
    refusal = "No conversation found with session ID: $(resumed)"
    # Its own line, bare (as the CLI prints it) or behind an "Error: " prefix a
    # later CLI may add; a line that merely mentions it (a log of an earlier
    # attempt) does not count
    return any(l -> strip(l) in (refusal, "Error: " * refusal), split(res.stderr, '\n'))
end

"""
    interpret_claude_run(res, duration_ms, timeout_s; resumed="") -> ClaudeResult

Turn one finished `claude` run (the NamedTuple from `_run_claude_once`:
`exitcode`, `stdout`, `stderr`, `timed_out`) into a `ClaudeResult`. The
subprocess and its retries stay in `run_claude`; this part reads only the
captured output. `resumed` is the session id the run was given with `--resume`
("" for none).

A non-zero exit keeps the `session_id` of the CLI's stdout result object when it
printed one: with `--output-format json` it does on a failed exit too (a step
limit, a usage limit), so the thread can resume that session. A timeout keeps
the id of a result printed before the overrun, else the session it resumed (the
CLI writes the transcript as it goes and keeps the id across `--resume`); a
fresh run that timed out has none. A refused resume sets `session_missing`
([`resume_refused`](@ref)).
"""
function interpret_claude_run(res, duration_ms::Integer, timeout_s::Real; resumed::AbstractString="")
    if res.timed_out
        @warn "SlackClaw: claude timed out" timeout_s
        # A result printed before the overrun still names the run's session;
        # else a resumed run worked in the session it resumed (the CLI writes
        # the transcript as it goes, under the same id), so that is its session
        sid = stdout_session_id(res.stdout)
        isempty(sid) && (sid = String(resumed))
        return ClaudeResult(false, "Timed out after $(timeout_s)s", duration_ms, 0.0, sid)
    end

    if res.exitcode != 0
        msg = exit_failure_message(res.exitcode, res.stdout, res.stderr)
        sid = stdout_session_id(res.stdout)
        missing_session = resume_refused(res, resumed)
        @error "SlackClaw: claude dispatch failed" exitcode=res.exitcode reason=msg session_id=sid session_missing=missing_session stderr=strip(res.stderr)
        return ClaudeResult(false, msg, duration_ms, 0.0, sid, missing_session)
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
        # Couldn't even spawn (`claude` not on PATH, a missing repo_dir). The
        # error's own text spells out the whole command with its environment,
        # which holds the run's credentials, and this text is posted to Slack:
        # report only the error's code and the folder (any user name or
        # password in it masked), and say so when the folder is what is missing.
        why = e isa Base.IOError ? "$(Base.struverror(e.code)) ($(Base.uverrorname(e.code)))" :
                                   string(nameof(typeof(e)))
        dir = replace(cmd isa Cmd ? cmd.dir : "", r"://[^/\s@]+@" => "://…@")
        msg = isempty(dir) ? "failed to start claude: $why" :
              !isdir(dir) ? "failed to start claude: its folder $dir does not exist" :
                            "failed to start claude in $dir: $why"
        return (exitcode = -1, stdout = "", stderr = msg, timed_out = false)
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
            idx = findlast(d -> d isa AbstractDict && get(d, "type", "") == "result", data)
            idx === nothing ? Dict() : data[idx]
        else
            data  # legacy single-object format
        end
        is_error = get(entry, "is_error", false)
        # A step-limit result carries no `result` text; posting "" would fail
        result_text = is_error && is_step_limit(entry) ? STEP_LIMIT_MESSAGE :
                      get(entry, "result", "")
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

"""
    stdout_failure_reason(stdout) -> String

The reason a failed `claude` run printed to stdout: the `result` text of its JSON
result object (the last `"type" => "result"` entry of an array, or the object
itself), or the raw stdout when it is not JSON. Decoded here, not by
`parse_claude_output`, whose catch-all would post the whole JSON envelope when
`result` is null or not a string. Returns "" when there is no string reason.
"""
function stdout_failure_reason(stdout::AbstractString)
    data = try
        JSON.parse(stdout)
    catch
        # Not valid JSON -- the raw stdout is the reason
        return _clip_tail(String(strip(stdout)))
    end
    entry = result_entry(data)
    entry === nothing && return ""
    text = get(entry, "result", nothing)
    text isa AbstractString || return ""
    return _clip_head(String(strip(text)))
end

"""
    result_entry(data) -> Union{AbstractDict,Nothing}

The CLI's result object in parsed stdout: the last `"type" => "result"` entry of
an array, or the object itself. `nothing` when there is none.
"""
function result_entry(data)
    entry = if data isa AbstractVector
        idx = findlast(d -> d isa AbstractDict && get(d, "type", "") == "result", data)
        idx === nothing ? nothing : data[idx]
    elseif data isa AbstractDict && get(data, "type", "result") != "result"
        nothing     # a lone event of another type (e.g. system init) is no result
    else
        data
    end
    return entry isa AbstractDict ? entry : nothing
end

"""`result_entry` of raw stdout; `nothing` when stdout is not JSON."""
stdout_result_entry(stdout::AbstractString) =
    try
        result_entry(JSON.parse(stdout))
    catch
        nothing
    end

"""
    stdout_session_id(stdout) -> String

The `session_id` of the CLI's result object on stdout, or "" when stdout is not
JSON or carries no string id.
"""
function stdout_session_id(stdout::AbstractString)
    entry = stdout_result_entry(stdout)
    entry === nothing && return ""
    sid = get(entry, "session_id", nothing)
    return sid isa AbstractString ? String(sid) : ""
end

"""
Reason posted for a run the CLI stopped at `--max-turns` (result subtype
`error_max_turns`). Its result object has no `result` text, so the reason was
the bare exit code before.
"""
const STEP_LIMIT_MESSAGE = "Claude stopped at the step limit before finishing."

"""Whether a CLI result object is a step-limit stop (`subtype` `error_max_turns`)."""
is_step_limit(entry) = entry isa AbstractDict && get(entry, "subtype", "") == "error_max_turns"

# Reasons are capped at 500 characters with an explicit marker. A parsed result
# keeps its head (where the reason is); raw stdout and the stderr tail keep their end.
_clip_head(s::AbstractString) = length(s) > 500 ? first(s, 500) * " …" : s
_clip_tail(s::AbstractString) = length(s) > 500 ? "… " * last(s, 500) : s

"""
    exit_failure_message(exitcode, stdout, stderr) -> String

Describe a non-zero `claude` exit for the Slack reply. With `--output-format json`
the CLI prints its result object to stdout even when it fails, so the reason is
that object's `result` text (see `stdout_failure_reason`). Only when stdout carries
no reason is the stderr tail used, labelled `stderr:` because it is evidence
rather than a parsed reason. A step-limit stop gets [`STEP_LIMIT_MESSAGE`](@ref).
"""
function exit_failure_message(exitcode::Integer, stdout::String, stderr::String)
    is_step_limit(stdout_result_entry(stdout)) && return STEP_LIMIT_MESSAGE
    reason = stdout_failure_reason(stdout)
    if !isempty(reason)
        return "Claude exited non-zero (code $(exitcode)): $(reason)"
    end
    err = strip(stderr)
    isempty(err) && return "Claude exited non-zero (code $(exitcode))"
    return "Claude exited non-zero (code $(exitcode)), stderr: $(_clip_tail(String(err)))"
end
