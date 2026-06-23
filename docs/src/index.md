```@meta
CurrentModule = SlackClaw
```

# SlackClaw

Slack-to-[Claude Code](https://docs.anthropic.com/en/docs/claude-code) bridge: [SlackClaw](https://github.com/LidkeLab/SlackClaw.jl) watches Slack channels, dispatches messages to the `claude` CLI as subprocesses, and posts the results back as threaded replies. Messages arrive in real time over [Slack Socket Mode](socket-mode.md) (push).

!!! note "vs. the Slack MCP plugin"
    The Slack MCP plugin gives an interactive Claude session tools to *operate*
    Slack (read, search, post). SlackClaw is the inverse — Slack as a *frontend*
    to autonomous Claude Code agents on your repos, triggered by incoming
    messages over Socket Mode, with no human in a Claude client. They are
    complementary: a SlackClaw-dispatched agent can itself load the MCP plugin
    for richer Slack tooling.

## Example use cases

- **Fix a bug or add a feature from Slack** — Claude edits files and runs the tests in `repo_dir`, then replies in the thread (ask it to commit — SlackClaw doesn't on its own); reply in-thread to iterate (same session resumed).
- **Get a plot back as an image** — Claude generates a figure and uploads it to the thread (file/image upload is built in).
- **Periodically scan your repos** — configure proactive mode to ask Claude on a schedule to check for new PRs, failing CI, or stale branches, posting only when there's something worth saying.
- **Kick off a long job and walk away** — Claude can post progress by writing the status file and schedules a follow-up with `[SCHEDULE: 2h: …]`.
- **Triage across repos from one channel** — each repo's monitor picks up only what's relevant to it (relevance-filtered listening) and answers in its own channel.
- **Ask about a codebase from your phone** — Claude reads the repo and explains, no terminal needed.

See [Use Cases](use-cases.md) for step-by-step setup of each.

## Features

- **Real-time push** — messages arrive over Slack Socket Mode (sub-second), with a reconciliation poll as a gap-fill safety net
- **Guided setup** — [`SlackClaw.setup()`](setup.md) provisions the Slack app from a manifest and wires up the tokens
- **Multi-turn sessions** — thread replies resume the same Claude session (`--resume`)
- **Agent directives** — Claude controls its own flow with `[CONTINUE]` and `[SCHEDULE: 2h: ...]`
- **Concurrent tasks** — each message runs as an async task, capped by `max_concurrent_tasks`
- **Multi-channel listening** — read-only channels with a relevance filter; responses land in the primary channel
- **Proactive mode** — periodic autonomous checks that post only when there is something to say
- **Persistence** — cursors, thread sessions, and scheduled tasks survive restarts (`.slackclaw_state.json`)

## Installation

```julia
using Pkg
Pkg.add("SlackClaw")                                       # once registered in General
# before registration: Pkg.add(url="https://github.com/LidkeLab/SlackClaw.jl")
```

Requires Julia ≥ 1.10 and an authenticated `claude` CLI on the host.

## Quick start

First provision the Slack app — the wizard handles everything that can be automated (see [Slack App Setup](setup.md)):

```julia
using SlackClaw
SlackClaw.setup()
```

`setup()` writes `slackclaw.env`. `source slackclaw.env`, then run a monitor:

```julia
run_monitor(SlackClawConfig(repo_dir = "/path/to/your/repo"))   # blocking; Ctrl-C to stop
```

To serve many channels of one workspace on a single socket:

```julia
run_socket_fleet([
    SlackClawConfig(slack_channel_id="C_A", repo_dir="/repo/a"),
    SlackClawConfig(slack_channel_id="C_B", repo_dir="/repo/b"),
])
```

## How a message flows

1. A user posts in the monitored channel; Slack pushes the event over the socket.
2. SlackClaw reacts with 👀 and spawns `claude --print` in `repo_dir`, with the message as the prompt.
3. The response is posted as a threaded reply (long responses are split across multiple messages).
4. Replies in that thread resume the same Claude session; ✅ / ❌ reactions mark completion.
5. If the response ends in `[CONTINUE]`, Claude is re-invoked immediately; `[SCHEDULE: 30m: check results]` queues a future invocation.

## Documentation

- [Slack App Setup](setup.md) — the `setup()` wizard, the app manifest, tokens, channel wiring
- [Use Cases](use-cases.md) — step-by-step setup for each use case
- [Features](features.md) — agent directives, multi-channel listening, proactive mode, progress updates
- [Socket Mode](socket-mode.md) — push delivery: how it works, reliability, the fleet, troubleshooting
- [API Reference](api.md) — all docstrings
```
