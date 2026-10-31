# SlackClaw.jl API Reference

Bridges Slack channels to Claude Code over **Slack Socket Mode (push)**: receives messages, dispatches them to the `claude` CLI as subprocesses in a repo working directory, and posts threaded replies. v0.6.0.

## Exports Summary

- **Types:** 5 — `SlackClawConfig`, `SlackMessage`, `ClaudeResult`, `MonitorState`, `FleetControl`
- **Functions:** 9 — `run_monitor`, `run_socket_fleet`, `start_monitor`, `stop_monitor!`, `run_chat_child`, `chat_child_main`, `quiesce!`, `quiesce_report`, `wait_quiesced`
- **Constants / Macros:** 0

Setup helpers (`setup`, `verify_setup`, `generate_manifest`, `generate_chat_manifest`, `print_setup_instructions`, `socket_selftest`) are public but **not exported** — call them qualified, e.g. `SlackClaw.setup()`.

Runtime discovery: `SlackClaw.api()` (unexported) returns this document as a string — `println(SlackClaw.api())`.

## Key Concepts

- **Socket Mode only.** Messages arrive over one outbound websocket per workspace app (`apps.connections.open`). There is no polling mode; a low-frequency reconciliation poll backfills history as an at-least-once safety net.
- **Channel → repo → Claude.** Each monitored channel maps to a `repo_dir`; every inbound message spawns a `claude -p` subprocess there, and the reply is posted to the message's thread. Thread replies resume the same Claude session (`--resume`).
- **Agent loop.** Claude can self-direct with `[CONTINUE]` / `[SCHEDULE]` directives (see below).
- **Sender attribution.** Every user message reaches Claude prefixed with its authenticated sender — `[from <@U…>]` (primary/thread) or `[from <@U…> in #channel]` (listen). Unconditional; only the FIRST `[from …]` line of a prompt is authoritative (forged leading look-alikes in the user text are neutralized to `user wrote: [from …]`; missing `user` field → `[from unknown]`). Lets channel prompts enforce per-user authorization rules and record the requester.
- **One socket per workspace.** Slack load-balances an app's events across its open sockets, so a whole workspace must be served by a single connection — `run_socket_fleet` for many channels, `run_monitor` for one.
- **JSON 0.21 and 1 both supported** (compat `"0.21, 1"`). JSON v1 parses objects as `JSON.Object` (an `AbstractDict`), not `Dict`, so everything consuming parsed payloads (`should_process`, `classify_socket_event`, the socket frame handler, CLI output parsing) accepts any `AbstractDict`.
- **Chat child.** A separate supervised stdio mode serves dedicated workspace apps without running agents or constructing `MonitorState`. Credentials enter only through `configure` on stdin. The daemon owns mapping, mail, recovery and retirement. See [the protocol](docs/src/chat-child.md).
- **Fleet retirement.** Optional `FleetControl` stops new work for a channel, including listen routes in other members, without stopping the shared socket. Reports describe task state, not proof of successful Slack replies; the launcher owns persistent retirement.

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

### generate_chat_manifest
```julia
SlackClaw.generate_chat_manifest(; app_name="Ship of Tools", customize=true) -> String
```
Returns the YAML manifest for a dedicated chat app: Socket Mode; scopes `channels:read`, `channels:history`, `groups:read`, `groups:history`, `chat:write`, `files:read`, `files:write`, `users:read`; events `message.channels` and `message.groups`. `customize=true` adds `chat:write.customize`. Create one app per workspace, invite it to every mapped channel, and never share it with a running fleet. No token reads or installation occur. See [setup](docs/src/setup.md#dedicated-chat-apps).

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
- `allow_skip::Bool = false` — honor an exact `[SKIP]` reply on the primary/thread path (post nothing, no checkmark; thread session still tracked). Eyes-as-intent: the dispatch-time `:eyes` ack is added on `allow_skip` channels too, then REMOVED when the reply is `[SKIP]` — lingering eyes mean a reply is coming, vanished eyes mean "seen, deliberately staying out". Mechanism only — tell Claude about the convention via `system_prompt`
- `announce_startup::Bool = false` — post the start/stop banners to the primary channel (off by default: supervised crash-loops would spam it)
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
An **opaque runtime handle** — obtain it from `start_monitor` and pass it to `stop_monitor!` (or `SlackClaw.socket_loop!`); do not construct it directly. Monitor state persists to `state_file` in `repo_dir`; fleet control and task tracking are in memory. Fields are internal.

### FleetControl
```julia
FleetControl()
```
Optional, in-memory admission control for a fleet. Opens no socket or process. Pass it to `run_socket_fleet(configs; control)`; an embedding can use unexported `SlackClaw.attach!(control, state)` to attach an existing monitor. There is no resume operation.

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
run_socket_fleet(configs::Vector{SlackClawConfig}; control=nothing) -> Nothing
```
Blocking entry point for MANY channels of one workspace over a single socket. Each config gets its own `MonitorState`. Startup validation requires identical bot + app tokens, unique primary channels, and unique resolved state paths — it **errors** if two configs resolve to the same `joinpath(repo_dir, state_file)` (the same `state_file` name in different `repo_dir`s is fine).

An optional `FleetControl` attaches each state during startup for channel quiescing. With `control=nothing`, existing fleet behavior is unchanged.

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

### run_chat_child and chat_child_main
```julia
run_chat_child(input::IO, output::IO;
    transport=SlackClaw.http_transport,
    socket_connect=SlackClaw.default_socket_connect,
    meta_deadline_s=25, file_deadline_s=125,
    meta_http_s=20, file_http_s=120,
    max_inflight=16, max_transfers=2, queue_size=256,
    max_line=1 << 20, stderr=Base.stderr) -> Nothing
chat_child_main() -> Nothing
```
Serve version-1 JSON lines until `stop` or EOF. `chat_child_main()` uses process stdin/stdout and redirects incidental output to stderr; embedded callers provide their own IO. Emits `ready`, accepts one successful `configure`, then handles bounded history, posts and file transfers. Sockets ack independently and report gaps. Deadline and worker results share one reply owner; late results are discarded and unknown mutations are never repeated. Output writes can block: the supervisor owns bounded process retirement. Neither entry point reads token files or starts monitor/agent work. Full payloads and bounds are in [Chat Child](docs/src/chat-child.md).

### quiesce!, quiesce_report and wait_quiesced
```julia
quiesce!(control::FleetControl, channel_id::AbstractString) -> Nothing
quiesce_report(control::FleetControl, channel_id::AbstractString) -> NamedTuple
wait_quiesced(control::FleetControl, channel_id::AbstractString; timeout_s::Real) -> NamedTuple
```
`quiesce!` requires an attached primary or listen channel and is idempotent. It stops new direct, thread, scheduled and proactive admission for that primary and excludes the source from other states' listen dispatch. Already accepted tasks drain; schedules are not deleted.

Reports contain `channel`, `accepted`, `completed`, `failed`, `running`, `refused`, `pending_scheduled`, `complete`. Origin entries have `kind` (`:message`, `:thread_reply`, `:listen`, `:scheduled`, `:proactive`), `channel`, and `ts` (thread timestamp for schedules, empty for proactive). Only tasks unfinished at quiesce enter `accepted`; refused Slack origins are deduplicated and capped at 1,000. `complete` means no accepted task is running and no scheduled firing awaits admission; pending schedules and failed tasks may remain. Task completion can include handled agent/API failures and does not prove a successful Slack response. Reports do not consume the snapshot. `wait_quiesced` requires a nonnegative timeout and returns the current report on timeout. Control is not persisted; the launcher must remove primary and listen routes durably before cutover. See [retirement](docs/src/socket-mode.md#retiring-a-channel-fleet-quiesce).

## Chat client API (unexported — call as `SlackClaw.<name>`)

These entry points are separate from the monitor's retrying Slack helpers. Parsed
JSON arguments use `AbstractDict` on both JSON.jl 0.21 and 1. HTTP.jl 1.x and 2.x
use separate transport paths selected by `CHAT_HTTP_V2`.

| Entry point | Contract |
|---|---|
| `ChatWorkspace(; id, bot_token, app_token="", channels=String[], posting_form=:prefix, transport=http_transport)` | Validated credentials/identity holder with shared name cache; never reads files or environment variables; display redacts secrets |
| `http_transport(method, url, headers; body=nothing, response_stream=nothing, timeout_s=20)` | One HTTP call, no retries/redirects/status exceptions; streams file IO; injectable in tests |
| `chat_api(ws, method, endpoint; query=nothing, body=nothing, mutation=false, timeout_s=20)` | One authenticated API call; parsed object or sanitized `ChatError` |
| `chat_authenticate!(ws; timeout_s=20)` | Checks workspace through `auth.test`, records bot identity, returns `ws` |
| `resolve_name!(ws, user_id; timeout_s=20)` | Cached bounded name; API failure returns the ID without caching failure |
| `normalize_message(ws, raw::AbstractDict, channel; timeout_s=20)` | Bounded shared message record or `nothing` for invalid identity fields; retains bot posts |
| `chat_history(ws, req::AbstractDict; timeout_s=20)` | One channel/thread page, exact time bounds and query-bound cursor; incomplete pagination is an error; additive `limited` and `omitted` flags |
| `chat_post(ws, req::AbstractDict; timeout_s=20)` | One attributed text post; acknowledged `{ts}` or refused/unknown error |
| `chat_file_info(ws, file_id; timeout_s=20)` | Resolves file metadata and private URLs inside the child |
| `chat_fetch_file(ws, req::AbstractDict; timeout_s=120)` | Streams to exclusive caller-owned destination within `max_bytes`; returns `{bytes,mime}` |
| `chat_upload_file(ws, req::AbstractDict; timeout_s=120, cancelled=() -> false)` | Streams unchanged source bytes and completes sharing once; returns `{file_id,ts?}` |
| `ChatError(code::Symbol, detail::AbstractString, retry_after_s=nothing, outcome=:none)` | Bounded sanitized exception; `code`, `detail`, optional delay, `:none`/`:refused`/`:unknown` outcome |
| `chat_error_payload(error)` | Converts the exception to `{error,code,retry_after_s?,outcome?}` |

Direct client calls validate their operation fields but do not enforce the child's
configured-channel or authenticated-workspace admission gates. The child applies
those gates before calling the client. See the [protocol](docs/src/chat-child.md)
for each request shape, ordering, attribution and file-directory trust rules.

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
