# SlackClaw

[![Build Status](https://github.com/LidkeLab/SlackClaw.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/LidkeLab/SlackClaw.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/LidkeLab/SlackClaw.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/LidkeLab/SlackClaw.jl)

Slack-to-Claude Code bridge. SlackClaw monitors a Slack channel, dispatches messages to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as subprocesses, and posts results back as threaded replies. Supports multi-turn sessions, concurrent tasks, and an agent loop with `[CONTINUE]`/`[SCHEDULE]` directives for autonomous workflows.

## Prerequisites

- **Julia 1.10+**
- **Claude Code CLI** (`claude`) installed and authenticated on the host machine

## Slack App Setup (New Workspace)

### 1. Create the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App** > **From scratch**
2. Name it (e.g. "SlackClaw") and select your workspace

### 2. Configure Bot Permissions

Navigate to **OAuth & Permissions** and add these **Bot Token Scopes**:

| Scope | Purpose |
|-------|---------|
| `channels:history` | Read messages in public channels |
| `channels:read` | List channels and get channel info |
| `chat:write` | Post messages and thread replies |
| `reactions:write` | Add emoji reactions (status indicators) |

### 3. Install to Workspace

1. Go to **Install App** in the sidebar and click **Install to Workspace**
2. Authorize the requested permissions
3. Copy the **Bot User OAuth Token** (`xoxb-...`) — this is your `SLACK_BOT_TOKEN`

### 4. Invite the Bot to a Channel

In Slack, go to the channel you want to monitor and run:
```
/invite @SlackClaw
```

### 5. Get the Channel ID

Right-click the channel name > **View channel details** > scroll to the bottom. The Channel ID looks like `C0123456789`. This is your `SLACK_CHANNEL_ID`.

## Adding a Channel/Repo to an Existing Workspace

If the Slack app is already installed in your workspace, you just need to point a new monitor instance at a different channel and repo directory.

### 1. Create or Choose a Channel

Create a new Slack channel for the repo, or use an existing one.

### 2. Invite the Bot

```
/invite @SlackClaw
```

### 3. Get the Channel ID

Right-click channel name > **View channel details** > copy the Channel ID from the bottom.

### 4. Run a Monitor for That Channel/Repo

Each monitor instance watches one channel and operates in one repo directory. Run a separate instance per channel:

```julia
using SlackClaw

run_monitor(SlackClawConfig(
    slack_bot_token = ENV["SLACK_BOT_TOKEN"],       # same token for the whole workspace
    slack_channel_id = "C0NEW_CHANNEL_ID",          # the new channel
    repo_dir = "/path/to/your/repo",                # working directory for Claude
    model = "sonnet",                               # optional: claude model
    max_budget_usd = 5.0,                           # optional: per-invocation budget cap
))
```

You can run multiple monitors in the same Julia process or in separate processes — they share nothing except the Slack bot token.

## Environment Variables

```bash
export SLACK_BOT_TOKEN="xoxb-..."     # Bot User OAuth Token
export SLACK_CHANNEL_ID="C0123456789" # Default channel (can override per monitor)
```

## Quick Start

```julia
using SlackClaw

# Blocking — runs until Ctrl-C
run_monitor(SlackClawConfig())
```

Or with explicit options:

```julia
run_monitor(SlackClawConfig(
    repo_dir = "/home/user/myproject",
    model = "sonnet",
    max_budget_usd = 1.0,
    poll_interval_s = 30,
    max_concurrent_tasks = 3,
))
```

For non-blocking usage:

```julia
state = start_monitor(SlackClawConfig())
# ... do other things ...
stop_monitor!(state)
```

## Configuration

All options are fields on `SlackClawConfig`:

| Field | Default | Description |
|-------|---------|-------------|
| `slack_bot_token` | `ENV["SLACK_BOT_TOKEN"]` | Bot OAuth token |
| `slack_channel_id` | `ENV["SLACK_CHANNEL_ID"]` | Channel to monitor |
| `poll_interval_s` | `10` | Seconds between polls |
| `repo_dir` | `pwd()` | Working directory for Claude |
| `model` | `""` (CLI default) | Claude model name |
| `max_budget_usd` | `0.0` (no limit) | Budget cap per invocation |
| `claude_timeout_s` | `3600` | Max seconds per Claude call |
| `max_turns` | `30` | Max agent turns per invocation |
| `max_concurrent_tasks` | `5` | Parallel Claude invocations |
| `max_active_threads` | `10` | Tracked thread sessions (oldest expire) |
| `max_continue` | `10` | Max consecutive `[CONTINUE]` directives |
| `agent_directives` | `true` | Enable `[CONTINUE]`/`[SCHEDULE]` support |
| `system_prompt` | *(brevity prompt)* | System prompt prepended to each invocation |
| `allowed_tools` | `[]` | Restrict Claude to specific tools |

## How It Works

1. **Poll** — Fetches new channel messages and thread replies every `poll_interval_s` seconds
2. **Dispatch** — Each message spawns an async Claude invocation in the configured `repo_dir`
3. **React** — Adds emoji reactions: :eyes: (processing), :white_check_mark: (success), :x: (error)
4. **Thread** — All responses go to the message thread, preserving conversation context
5. **Resume** — Thread replies continue the same Claude session via `--resume`
6. **Persist** — Sessions and scheduled tasks survive restarts (saved to `.slackclaw_state.json`)

### Agent Directives

When `agent_directives` is enabled (default), Claude can control its own execution flow:

- **`[CONTINUE]`** — Immediately re-invoke in the same session for multi-step work
- **`[CONTINUE: next step description]`** — Re-invoke with a specific follow-up prompt
- **`[SCHEDULE: 2h: check pipeline results]`** — Schedule a future invocation (supports `30m`, `1h`, `2h30m`, etc.)

If no directive is present, the task is considered complete.

## Running as a Service

A simple systemd unit or tmux session works well:

```bash
# tmux approach
tmux new -s slackclaw
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_CHANNEL_ID="C0123456789"
julia --project=/path/to/SlackClaw -e "using SlackClaw; run_monitor(SlackClawConfig(repo_dir=\"/path/to/repo\"))"
```

For multiple channels, run one tmux pane or systemd unit per channel/repo pair.
