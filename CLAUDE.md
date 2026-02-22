# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

SlackClaw is a Julia package that bridges Slack channels to Claude Code. It polls Slack channels for messages, dispatches them to the Claude CLI as subprocesses, and posts results back to threads. Supports multi-turn sessions, agent directives (`[CONTINUE]`/`[SCHEDULE]`), concurrent tasks, multi-channel listening, proactive mode, status file watching, and state persistence across restarts.

## Commands

```bash
# Run tests
julia --project -e "using Pkg; Pkg.test()"

# Run tests directly
julia --project test/runtests.jl

# Start the monitor (requires SLACK_BOT_TOKEN and SLACK_CHANNEL_ID env vars)
julia --project -e "using SlackClaw; run_monitor(SlackClawConfig())"
```

Tests cover pure logic (directive parsing, message filtering, Claude output parsing, config defaults). Slack API and monitor loop are not tested (would require mocking).

## Required Environment

- `SLACK_BOT_TOKEN` — Bot token with scopes: `channels:history`, `channels:read`, `groups:history`, `chat:write`, `reactions:write`
- `SLACK_CHANNEL_ID` — Target channel to monitor

## Architecture

Six source files, all included from `SlackClaw.jl`:

- **config.jl** — `SlackClawConfig` kwdef struct with all settings (poll interval, model, budget, timeouts, directive toggles)
- **message_types.jl** — `SlackMessage` struct; `parse_slack_messages()` and `should_process()` filtering (skips bots, self, empty)
- **directives.jl** — Agent control flow: `parse_directives()` extracts `[CONTINUE]`/`[SCHEDULE: duration: prompt]`/done from response text via regex
- **slack_api.jl** — HTTP wrappers for Slack Web API with rate-limit retry (exponential backoff). All channel-scoped functions accept an explicit `channel_id` kwarg (defaults to `config.slack_channel_id`)
- **claude_runner.jl** — `run_claude()` spawns `claude --print --output-format json --dangerously-skip-permissions` subprocess; returns `ClaudeResult` (success, text, cost, session_id). Strips all `CLAUDE_*` env vars from subprocess environment to prevent session leakage. Appends `DIRECTIVE_INSTRUCTIONS` to system prompt when `agent_directives` is enabled.
- **monitor.jl** — Core polling loop and agent loop. Contains `MonitorState`, `ThreadSession`, `ScheduledTask`, persistence via `.slackclaw_state.json`. `ThreadSession` carries `channel_id` for multi-channel thread tracking

### Data Flow

1. `poll_once!()` fetches new channel messages → parses/filters → `dispatch_command!()` for each
2. Also polls tracked thread sessions for replies → `dispatch_thread_reply!()`
3. Polls listen channels → `poll_listen_channels!()` → `dispatch_listen_command!()` (relevance-filtered, posts to primary channel only if relevant)
4. Checks and fires due `ScheduledTask`s
5. `check_proactive!()` runs periodic autonomous checks if enabled
6. `dispatch_command!()` intercepts `proactive every/on/off` commands, otherwise adds eyes reaction and calls `run_agent_loop!()` as `@async` task
6. `run_agent_loop!()` loops: run Claude → parse directives → post response → if `:continue` re-invoke, if `:schedule` save future task, else break
7. Status file (`.slackclaw_status`) watched in background during execution, updates posted to thread

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
