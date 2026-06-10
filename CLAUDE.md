# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

SlackClaw is a Julia package that bridges Slack channels to Claude Code. It receives Slack messages (polling by default, or push via Socket Mode), dispatches them to the Claude CLI as subprocesses, and posts results back to threads. Supports multi-turn sessions, agent directives (`[CONTINUE]`/`[SCHEDULE]`), concurrent tasks, multi-channel listening, proactive mode, status file watching, and state persistence across restarts.

## Commands

```bash
# Run tests
julia --project -e "using Pkg; Pkg.test()"

# Run tests directly
julia --project test/runtests.jl

# Start the monitor (requires SLACK_BOT_TOKEN and SLACK_CHANNEL_ID env vars)
julia --project -e "using SlackClaw; run_monitor(SlackClawConfig())"
```

Tests cover pure logic (directive parsing, message filtering, Claude output parsing, socket event classification, cursor claims, response chunking, config defaults). Slack API, monitor loop, and websocket are not tested (would require mocking).

## Required Environment

- `SLACK_BOT_TOKEN` — Bot token with scopes: `channels:history`, `channels:read`, `groups:history`, `chat:write`, `reactions:write`
- `SLACK_CHANNEL_ID` — Target channel to monitor
- `SLACK_APP_TOKEN` — App-level `xapp-` token with `connections:write` (only for `socket_mode=true`; app must have Socket Mode enabled and bot events `message.channels`/`message.groups`/`message.im` subscribed)

## Architecture

Seven source files, all included from `SlackClaw.jl`:

- **config.jl** — `SlackClawConfig` kwdef struct with all settings (poll interval, model, budget, timeouts, directive toggles)
- **message_types.jl** — `SlackMessage` struct; `parse_slack_messages()` and `should_process()` filtering (skips bots, self, empty)
- **directives.jl** — Agent control flow: `parse_directives()` extracts `[CONTINUE]`/`[SCHEDULE: duration: prompt]`/done from response text via regex
- **slack_api.jl** — HTTP wrappers for Slack Web API with rate-limit retry (exponential backoff). All channel-scoped functions accept an explicit `channel_id` kwarg (defaults to `config.slack_channel_id`)
- **claude_runner.jl** — `run_claude()` spawns `claude --print --output-format json --dangerously-skip-permissions` subprocess; returns `ClaudeResult` (success, text, cost, session_id). Strips all `CLAUDE_*` env vars from subprocess environment to prevent session leakage. Appends `DIRECTIVE_INSTRUCTIONS` to system prompt when `agent_directives` is enabled.
- **monitor.jl** — Core polling loop and agent loop. Contains `MonitorState`, `ThreadSession`, `ScheduledTask`, persistence via `.slackclaw_state.json`. `ThreadSession` carries `channel_id` for multi-channel thread tracking. `reconcile_messages!` is the full message-fetch pass (primary history + threads + listen channels); `claim_*!` cursor gates make dispatch idempotent. `post_response` chunks long text across multiple thread messages (`chunk_text`)
- **socket_mode.jl** — Socket Mode (push) event loop: `socket_loop!` connects via `apps.connections.open` (app-level token), acks envelopes immediately, and routes events through `classify_socket_event` into the same dispatch paths. `socket_housekeeping!` fires scheduled/proactive checks and the periodic reconciliation poll

### Data Flow

1. `poll_once!()` fetches new channel messages → parses/filters → `dispatch_command!()` for each
2. Also polls tracked thread sessions for replies → `dispatch_thread_reply!()`
3. Polls listen channels → `poll_listen_channels!()` → `dispatch_listen_command!()` (relevance-filtered, posts to primary channel only if relevant)
4. Checks and fires due `ScheduledTask`s
5. `check_proactive!()` runs periodic autonomous checks if enabled
6. `dispatch_command!()` intercepts `proactive every/on/off` commands, otherwise adds eyes reaction and calls `run_agent_loop!()` as `@async` task
6. `run_agent_loop!()` loops: run Claude → parse directives → post response → if `:continue` re-invoke, if `:schedule` save future task, else break
7. Status file (`.slackclaw_status`) watched in background during execution, updates posted to thread

### Socket Mode (Push)

With `socket_mode=true`, `run_monitor` runs `socket_loop!` instead of the poll loop (explicit selection — empty `app_token` is a startup error, never a silent fallback to polling). Flow:

1. `apps.connections.open` (app-level token) → short-lived `wss://` URL → `HTTP.WebSockets.open`
2. Slack pushes message events as envelopes; the read loop only parses, **acks immediately** (≈3s deadline), and enqueues onto a `Channel` — it never does API work, so a rate-limit retry in dispatch can't starve acks of queued frames
3. A **single FIFO consumer task** (`socket_event_consumer!`) drains the queue: `classify_socket_event()` (pure, tested) decides `:primary`/`:thread_reply`/`:listen`/`:ignore`; `route_socket_event!` claims the matching cursor, applies `should_process`, and calls the same `dispatch_*` functions as polling. Exactly one consumer — cursor claims need per-channel ts ordering (an out-of-order claim would advance the cursor past an undispatched message, which reconciliation can never recover)
4. Delivery is at-least-once with gaps across reconnects, so `reconcile_messages!` runs as a gap-fill poll on every (re)connect and every `reconcile_interval_s` (default 300s). The `claim_*!` gates (under `MonitorState.dispatch_lock`) drop anything the other path already dispatched, including Slack redeliveries
5. Disconnect frames (`refresh_requested` every few hours; `warning` ≈1min ahead) → reconnect with exponential backoff (reset on success); listen channels need no polling since all events arrive on the one socket
6. `socket_housekeeping!` (background task) fires `check_scheduled!`/`check_proactive!` every `poll_interval_s` and the reconciliation poll on its own cadence

Caveat for multi-instance setups: all channels of one Slack app arrive on one socket, and with several sockets open Slack load-balances each event to exactly one of them. Running one Socket Mode monitor per channel under the same app would drop events — Socket Mode wants one monitor per workspace token. Polling instances are unaffected.

### Concurrency

Each dispatch spawns an `@async` Task. Max `max_concurrent_tasks` (default 5) enforced. Busy threads report elapsed time to the user if they send another message.

### Multi-Channel Listening

`listen_channel_ids` configures channels to poll read-only. Messages from listen channels are prefixed with `[from #channel-name]` and run through a relevance filter: Claude is asked to respond `[SKIP]` if the message isn't relevant to the instance's repo/role. Only relevant messages get posted as new threads in the primary channel. Channel names are resolved via `conversations.info` on startup and cached. Polls are staggered (0.5s between channels) to avoid rate limits.

### Proactive Mode

When `proactive_enabled=true`, `check_proactive!()` fires every `proactive_interval_s` (default 3600s/1h). Fires when either `proactive_prompt` is non-empty or `.slackclaw_proactive_tasks` exists in `repo_dir`. Claude reads two files at runtime:

- **`.slackclaw_proactive_tasks`** — task suggestions (what to check). Written by the orchestrator at launch, editable anytime without restart. Claude reads this each cycle for current ideas.
- **`.slackclaw_proactive_log`** — post history (what was already reported). Appended automatically after each real post. Claude reads this to avoid repetition.

Behavioral rules (`[SKIP]` convention, conciseness) live in `PROACTIVE_PREFIX` constant. The `proactive_prompt` config string is appended if non-empty (backward compat / inline overrides). Only real content gets posted as a top-level message in the primary channel.

Dynamic control via Slack messages in the monitored channel:
- `proactive every 30m` / `proactive interval 2h` — adjust frequency
- `proactive on` / `proactive off` — toggle

### Persistence

State saved to `.slackclaw_state.json` in `repo_dir`: `last_ts`, thread sessions (with `channel_id`), scheduled tasks, `listen_last_ts` per listen channel, and `last_proactive` timestamp. Loaded on startup. Migrates legacy `.slackclaw_threads.json` format.

## Dependencies

`HTTP`, `JSON`, and `Dates` (stdlib). Julia >= 1.10.
