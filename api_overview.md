# SlackClaw.jl API Reference

Bridges Slack channels to Claude Code over **Slack Socket Mode (push)**: receives messages, dispatches them to the `claude` CLI as subprocesses in a repo working directory, and posts threaded replies. v0.4.0.

## Exports Summary

- **Types:** 4 — `SlackClawConfig`, `SlackMessage`, `ClaudeResult`, `MonitorState`
- **Functions:** 4 — `run_monitor`, `run_socket_fleet`, `start_monitor`, `stop_monitor!`
- **Constants / Macros:** 0

Setup helpers (`setup`, `verify_setup`, `generate_manifest`, `print_setup_instructions`, `socket_selftest`) are public but **not exported** — call them qualified, e.g. `SlackClaw.setup()`.

Runtime discovery: `SlackClaw.api()` (unexported) returns this document as a string — `println(SlackClaw.api())`.

## Key Concepts

- **Socket Mode only.** Messages arrive over one outbound websocket per workspace app (`apps.connections.open`). There is no polling mode; a low-frequency reconciliation poll backfills history as an at-least-once safety net.
- **Channel → repo → Claude.** Each monitored channel maps to a `repo_dir`; every inbound message spawns a `claude -p` subprocess there, and the reply is posted to the message's thread. Thread replies resume the same Claude session (`--resume`).
- **Agent loop.** Claude can self-direct with `[CONTINUE]` / `[SCHEDULE]` directives (see below).
- **One socket per workspace.** Slack load-balances an app's events across its open sockets, so a whole workspace must be served by a single connection — `run_socket_fleet` for many channels, `run_monitor` for one.

## Environment

All three are required (run `SlackClaw.setup()` to provision them):

| Var | Example | Purpose |
|-----|---------|---------|
| `SLACK_BOT_TOKEN` | `xoxb-…` | Bot OAuth token — all Slack Web API calls |
| `SLACK_APP_TOKEN` | `xapp-…` | App-level token (`connections:write`) — authorizes the socket |
| `SLACK_CHANNEL_ID` | `C0123456789` | Channel to monitor |

## Setup API (unexported — call as `SlackClaw.<name>`)

### setup
```julia
SlackClaw.setup(; repo_dir=pwd(), app_name="SlackClaw", write_env=true) -> NamedTuple
```
Interactive wizard. Writes/prints the Slack app manifest plus the grouped browser steps, prompts for the two tokens and the channel, then runs `verify_setup`. Returns the verify report.

### verify_setup
```julia
SlackClaw.verify_setup(; bot_token, app_token, channel,
                       repo_dir=pwd(), write_env=true,
                       env_path=joinpath(repo_dir, "slackclaw.env"),
                       announce=true) -> NamedTuple
```
Automated half of setup: validates the bot token (`auth.test`), resolves `channel` (name or ID), auto-joins public channels, runs a live socket self-test, and — with the defaults — writes a gitignored `slackclaw.env` (`write_env=true`) and posts a confirmation (`announce=true`, only when the bot is in the channel). Returns `(; ok, channel_id, bot_user_id, team, checks)`.

### generate_manifest
```julia
SlackClaw.generate_manifest(; app_name="SlackClaw", description="Bridges this Slack channel to Claude Code.") -> String
```
Returns a Slack app manifest (YAML) with all required bot scopes, the `message.channels` / `message.groups` / `message.im` events, and Socket Mode enabled. Paste into Slack → Create New App → From an app manifest.

### print_setup_instructions
```julia
SlackClaw.print_setup_instructions([io=stdout]; app_name="SlackClaw", manifest_path="") -> Nothing
```
Prints the manifest and the grouped human-only browser steps.

### socket_selftest
```julia
SlackClaw.socket_selftest(config::SlackClawConfig; timeout_s=15) -> Bool
```
Opens a Socket Mode connection and waits for Slack's `hello` frame. Returns `true` if it arrives before the timeout.

## Types

### SlackClawConfig
```julia
Base.@kwdef mutable struct SlackClawConfig
```
All settings for a monitor. Keyword constructor; the token/channel fields default to reading the env vars above.

**Fields (defaults):**
- `slack_bot_token::String = ENV["SLACK_BOT_TOKEN"]`
- `slack_channel_id::String = ENV["SLACK_CHANNEL_ID"]`
- `app_token::String = get(ENV, "SLACK_APP_TOKEN", "")` — required at runtime
- `reconcile_interval_s::Int = 300` — gap-fill reconciliation cadence
- `poll_interval_s::Int = 10` — background housekeeping cadence (scheduled/proactive + reconcile tick)
- `repo_dir::String = pwd()`
- `max_budget_usd::Float64 = 0.0` — `0` = no cap
- `model::String = ""` — `""` = CLI default
- `claude_timeout_s::Int = 3600`
- `max_turns::Int = 30`
- `allowed_tools::Vector{String} = String[]`
- `max_concurrent_tasks::Int = 5`
- `max_active_threads::Int = 3`
- `max_thread_idle_s::Int = 604800` — 7 d; `0` = never
- `max_continue::Int = 10` — max consecutive `[CONTINUE]`
- `system_prompt::String` — a Slack-formatting brevity prompt (full literal below)
- `agent_directives::Bool = true` — enable `[CONTINUE]`/`[SCHEDULE]`
- `state_file::String = ".slackclaw_state.json"`
- `status_file::String = ".slackclaw_status"`
- `status_poll_s::Int = 30`
- `bot_user_id::String = ""` — auto-filled at startup
- `listen_channel_ids::Vector{String} = String[]`
- `proactive_enabled::Bool = false`
- `proactive_prompt::String = ""`
- `proactive_interval_s::Int = 3600`

Default `system_prompt` (one line):

    Your responses are posted to a Slack channel as threaded replies. Keep under 2000 chars. Be concise and direct. Do NOT use markdown — Slack does not render it. Use Slack-native formatting: *bold*, _italic_, `code`, ```code blocks```. No headers (#), no dash-bullet lists. URLs work fine as plain text. If a task will take more than a few seconds, first reply with a brief message explaining what you are about to do and what the user should expect.

**Constructor:**
```julia
SlackClawConfig(; repo_dir="/path/to/repo", model="sonnet")   # env-backed tokens by default
```

### SlackMessage
```julia
struct SlackMessage
```
A parsed Slack message.
**Fields:** `ts::String`, `user::String`, `text::String`, `thread_ts::String`.

### ClaudeResult
```julia
struct ClaudeResult
```
Result of one `claude` CLI invocation.
**Fields:** `success::Bool`, `result_text::String`, `duration_ms::Int`, `cost_usd::Float64`, `session_id::String`.

### MonitorState
```julia
mutable struct MonitorState
```
An **opaque runtime handle** — obtain it from `start_monitor` and pass it to `stop_monitor!` (or `SlackClaw.socket_loop!`); do not construct it directly. Persisted to `state_file` in `repo_dir`. Its 12 fields are internal: `config`, `last_ts`, `running`, `active_tasks`, `timer`, `threads`, `busy_threads`, `scheduled`, `listen_last_ts`, `channel_names`, `last_proactive`, `dispatch_lock`.

## Functions

### run_monitor
```julia
run_monitor(config::SlackClawConfig) -> Nothing
```
Blocking entry point for ONE channel. Connects via Socket Mode and serves pushed events until interrupted (Ctrl-C). Requires `config.app_token` (errors at startup if empty). Fatal errors are appended to `.slackclaw_crash.log` in `repo_dir`.

**Example:**
```julia
run_monitor(SlackClawConfig(repo_dir="/path/to/repo"))
```

### run_socket_fleet
```julia
run_socket_fleet(configs::Vector{SlackClawConfig}) -> Nothing
```
Blocking entry point for MANY channels of one workspace over a single socket. Each config gets its own `MonitorState`. Startup validation requires identical bot + app tokens, unique primary channels, and unique resolved state paths — it **errors** if two configs resolve to the same `joinpath(repo_dir, state_file)` (the same `state_file` name in different `repo_dir`s is fine).

**Example:**
```julia
run_socket_fleet([
    SlackClawConfig(slack_channel_id="C_A", repo_dir="/repo/a"),
    SlackClawConfig(slack_channel_id="C_B", repo_dir="/repo/b"),
])
```

### start_monitor
```julia
start_monitor(config::SlackClawConfig) -> MonitorState
```
Authenticate, load persisted state, resolve listen-channel names, and post the startup banner — WITHOUT entering the message loop. For embedding, run `SlackClaw.socket_loop!(state)` yourself, then `stop_monitor!`.

### stop_monitor!
```julia
stop_monitor!(state::MonitorState) -> Nothing
```
Signal shutdown (`state.running = false`), wait for in-flight tasks, and post a shutdown notice. Does not force the websocket closed — an embedded loop exits at the next frame/reconnect, so stopping an idle socket is not instant.

## Agent Directives

When `agent_directives = true` (default), Claude controls its own flow by ending a response with:

- `[CONTINUE]` — re-invoke immediately in the same session
- `[CONTINUE: next step]` — re-invoke with a specific follow-up prompt
- `[SCHEDULE: 2h: check results]` — queue a future invocation (`30m`, `1h`, `2h30m`, …)

No directive = task complete. Consecutive `[CONTINUE]`s are capped at `max_continue`.

## Common Workflows

### First-time setup, then run
```julia
using SlackClaw
SlackClaw.setup()                          # provisions the app, writes slackclaw.env
# `source slackclaw.env`, then:
run_monitor(SlackClawConfig(repo_dir="/path/to/repo"))
```

### Whole workspace on one socket
```julia
using SlackClaw
bot = ENV["SLACK_BOT_TOKEN"]; app = ENV["SLACK_APP_TOKEN"]
run_socket_fleet([
    SlackClawConfig(slack_bot_token=bot, app_token=app, slack_channel_id="C_A", repo_dir="/repo/a"),
    SlackClawConfig(slack_bot_token=bot, app_token=app, slack_channel_id="C_B", repo_dir="/repo/b"),
])
```

### Non-interactive setup
```julia
using SlackClaw
println(SlackClaw.generate_manifest())     # paste into Slack "From an app manifest"
SlackClaw.verify_setup(; bot_token="xoxb-…", app_token="xapp-…", channel="#dev")
```
