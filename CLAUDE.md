# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

SlackClaw is a Julia package that bridges Slack channels to Claude Code. It polls Slack channels for messages, dispatches them to the Claude CLI as subprocesses, and posts results back to threads. Supports multi-turn sessions, agent directives (`[CONTINUE]`/`[SCHEDULE]`), concurrent tasks, multi-channel listening, status file watching, and state persistence across restarts.

## Commands

```bash
# Run tests
julia --project -e "using Pkg; Pkg.test()"

# Run tests directly
julia --project test/runtests.jl

# Start the monitor
julia --project -e "using SlackClaw; run_monitor(SlackClawConfig())"
```

## Required Environment

- `SLACK_BOT_TOKEN` — Bot token with scopes: `channels:history`, `channels:read`, `groups:history`, `chat:write`, `reactions:write`
- `SLACK_CHANNEL_ID` — Target channel to monitor

## Architecture

Six source files, all included from `SlackClaw.jl`:

- **config.jl** — `SlackClawConfig` kwdef struct with all settings (poll interval, model, budget, timeouts, directive toggles)
- **message_types.jl** — `SlackMessage` struct; `parse_slack_messages()` and `should_process()` filtering (skips bots, self, empty)
- **directives.jl** — Agent control flow: `parse_directives()` extracts `[CONTINUE]`/`[SCHEDULE: duration: prompt]`/done from response text via regex
- **slack_api.jl** — HTTP wrappers for Slack Web API with rate-limit retry (exponential backoff). All channel-scoped functions accept an explicit `channel_id` kwarg (defaults to `config.slack_channel_id`)
- **claude_runner.jl** — `run_claude()` spawns `claude --print --output-format json` subprocess; returns `ClaudeResult` (success, text, cost, session_id). Filters `CLAUDE_*` env vars from subprocess.
- **monitor.jl** — Core polling loop and agent loop. Contains `MonitorState`, `ThreadSession`, `ScheduledTask`, persistence via `.slackclaw_state.json`. `ThreadSession` carries `channel_id` for multi-channel thread tracking

### Data Flow

1. `poll_once!()` fetches new channel messages → parses/filters → `dispatch_command!()` for each
2. Also polls tracked thread sessions for replies → `dispatch_thread_reply!()`
3. Polls listen channels → `poll_listen_channels!()` → `dispatch_listen_command!()` (posts to primary channel)
4. Checks and fires due `ScheduledTask`s
5. `dispatch_command!()` adds eyes reaction, calls `run_agent_loop!()` as `@async` task
6. `run_agent_loop!()` loops: run Claude → parse directives → post response → if `:continue` re-invoke, if `:schedule` save future task, else break
7. Status file (`.slackclaw_status`) watched in background during execution, updates posted to thread

### Concurrency

Each dispatch spawns an `@async` Task. Max `max_concurrent_tasks` (default 5) enforced. Busy threads report elapsed time to the user if they send another message.

### Multi-Channel Listening

`listen_channel_ids` configures channels to poll read-only. Messages from listen channels are prefixed with `[from #channel-name]` and dispatched as new threads in the primary channel. Channel names are resolved via `conversations.info` on startup and cached. Polls are staggered (0.5s between channels) to avoid rate limits.

### Persistence

State saved to `.slackclaw_state.json` in `repo_dir`: `last_ts`, thread sessions (with `channel_id`), scheduled tasks, and `listen_last_ts` per listen channel. Loaded on startup. Migrates legacy `.slackclaw_threads.json` format.

## Dependencies

Only `HTTP` and `JSON`. Julia >= 1.10.
