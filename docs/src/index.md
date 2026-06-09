```@meta
CurrentModule = SlackClaw
```

# SlackClaw

Slack-to-[Claude Code](https://docs.anthropic.com/en/docs/claude-code) bridge: [SlackClaw](https://github.com/LidkeLab/SlackClaw.jl) watches Slack channels, dispatches messages to the `claude` CLI as subprocesses, and posts the results back as threaded replies.

## Features

- **Two delivery modes** — timer-driven polling (default) or push via [Slack Socket Mode](socket-mode.md) for sub-second latency
- **Multi-turn sessions** — thread replies resume the same Claude session (`--resume`)
- **Agent directives** — Claude controls its own flow with `[CONTINUE]` and `[SCHEDULE: 2h: ...]`
- **Concurrent tasks** — each message runs as an async task, capped by `max_concurrent_tasks`
- **Multi-channel listening** — read-only channels with a relevance filter; responses land in the primary channel
- **Proactive mode** — periodic autonomous checks that post only when there is something to say
- **Persistence** — cursors, thread sessions, and scheduled tasks survive restarts (`.slackclaw_state.json`)

## Installation

```julia
using Pkg
Pkg.develop(path="/path/to/SlackClaw")   # not registered; used as a local package
```

Requires Julia ≥ 1.10 and an authenticated `claude` CLI on the host.

## Quick start

Set up the Slack app first — see [Slack App Setup](setup.md). Then:

```julia
using SlackClaw

# Polling (default): SLACK_BOT_TOKEN and SLACK_CHANNEL_ID must be set
run_monitor(SlackClawConfig(repo_dir = "/path/to/your/repo"))
```

Push delivery via Socket Mode (additionally needs `SLACK_APP_TOKEN` and event
subscriptions — see [Socket Mode](socket-mode.md)):

```julia
run_monitor(SlackClawConfig(
    socket_mode = true,
    repo_dir = "/path/to/your/repo",
))
```

Non-blocking control:

```julia
state = start_monitor(SlackClawConfig())
# ...
stop_monitor!(state)
```

## How a message flows

1. A user posts in the monitored channel (received by poll or socket push).
2. SlackClaw reacts with 👀 and spawns `claude --print` in `repo_dir`, with the message as the prompt.
3. The response is posted as a threaded reply (long responses are split across multiple messages).
4. Replies in that thread resume the same Claude session; ✅ / ❌ reactions mark completion.
5. If the response ends in `[CONTINUE]`, Claude is re-invoked immediately; `[SCHEDULE: 30m: check results]` queues a future invocation.

## Documentation

- [Slack App Setup](setup.md) — tokens, scopes, event subscriptions, channel wiring
- [Socket Mode](socket-mode.md) — push delivery: how it works, configuration, troubleshooting
- [API Reference](api.md) — all docstrings
