# SlackClaw

[![Build Status](https://github.com/kalidke/SlackClaw.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/kalidke/SlackClaw.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/kalidke/SlackClaw.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/kalidke/SlackClaw.jl)

Slack-to-Claude Code bridge. SlackClaw watches Slack channels, dispatches messages to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as subprocesses, and posts results back as threaded replies. Messages arrive in real time over [Slack Socket Mode](https://api.slack.com/apis/socket-mode) (push). Supports multi-turn sessions, concurrent tasks, multi-channel listening, proactive checks, and an agent loop with `[CONTINUE]`/`[SCHEDULE]` directives for autonomous workflows.

## SlackClaw vs. the Slack MCP plugin

The Slack MCP plugin and SlackClaw solve opposite halves of "Slack + Claude":

- The **Slack MCP plugin** gives an interactive Claude session *tools to operate Slack* — read/search channels, post, react, canvases. The direction is **outbound**: Claude, driven by a human in a Claude client, reaches into Slack. It's pull-only and in-session — nothing runs when you aren't in a Claude session, and an incoming Slack message can't trigger anything.
- **SlackClaw** makes Slack a *frontend to autonomous Claude Code agents* on your repos. The direction is **inbound**: a Slack message arrives over Socket Mode, runs `claude` in a repo working directory, and the result posts back as a threaded reply — with no human in any Claude client.

Use **SlackClaw** when you want people to *use Claude from Slack* (phone, no terminal), trigger coding agents on your own machines, and run unattended/scheduled/proactive work. Use the **MCP plugin** when you're driving Claude and want it to read or post Slack as part of your work.

They're complementary, not competitors: a SlackClaw-dispatched agent can itself load the Slack MCP plugin to gain the rich read/search/canvas tooling that SlackClaw's own reply path doesn't provide.

## Example use cases

- **Fix a bug or add a feature from Slack.** "The CSV reader chokes on empty input — fix it and add a test." With full tool access in `repo_dir`, Claude edits files and runs the tests, then replies in the thread — ask it to commit, or set a commit policy in `system_prompt` (SlackClaw doesn't commit on its own). Reply in-thread to iterate; it resumes the same Claude session.
- **Get a plot back as an image.** "Plot the loss curve from run 42." Claude generates the figure, saves it, and uploads it to the thread — file/image upload is built in (the bundled `bin/slack-upload` helper + the `files:write` scope).
- **Periodically scan your repos.** With proactive mode configured, SlackClaw asks Claude on a schedule to run the checks you list (new PRs to review, failing CI, stale branches, …) and posts only when there's something worth flagging.
- **Kick off a long job and walk away.** "Start the training run and report when it finishes." Claude launches it, can post progress by writing the status file, and uses `[SCHEDULE: 2h: check results]` to schedule a follow-up.
- **Triage across repos from one channel.** Post in a shared hub channel; each repo's monitor picks up only what's relevant to it (relevance-filtered listening) and answers in its own channel.
- **Ask about a codebase from your phone.** "How does the reconciliation loop avoid double-dispatch?" Claude reads the repo and explains — no terminal needed.

Step-by-step setup for each is in the [Use Cases guide](docs/src/use-cases.md).

## Prerequisites

- **Julia 1.10+**
- **Claude Code CLI** (`claude`) installed and authenticated on the host machine
- **`curl` and `jq`** on the host — only needed for file/image upload (the `bin/slack-upload` helper)

## Setup

SlackClaw provisions its own Slack app. Run the wizard:

```julia
using SlackClaw
SlackClaw.setup()
```

It prints a Slack app **manifest** and the few browser steps only a human can do, then automates everything else — validating both tokens, resolving the channel, auto-joining public channels, a live Socket Mode self-test, and writing a gitignored `slackclaw.env`. The human steps are grouped into one browser session; there is no do-this-then-that-then-this-again back-and-forth.

The wizard walks you through these (all in one sitting at [api.slack.com/apps](https://api.slack.com/apps)):

1. **Create New App → From an app manifest**, paste the manifest, **Create**. The manifest pre-sets every scope, the message events, and Socket Mode — nothing to toggle by hand.
2. **Install to Workspace** → copy the **Bot User OAuth Token** (`xoxb-…`).
3. **Basic Information → App-Level Tokens** → generate one with `connections:write` → copy it (`xapp-…`).
4. *Only if your channel is private:* `/invite @SlackClaw` in it. (Public channels are auto-joined.)

Paste the two tokens and the channel name back into the wizard. It verifies the whole chain and writes `slackclaw.env`.

### Non-interactive

```julia
println(SlackClaw.generate_manifest())   # the YAML to paste into "From an app manifest"

SlackClaw.verify_setup(;
    bot_token = "xoxb-…",
    app_token = "xapp-…",
    channel   = "#dev",                  # name or ID
)
```

### What the app uses (reference)

You don't configure these by hand — the manifest does — but for transparency:

| Bot scope | Purpose |
|-----------|---------|
| `channels:history` / `groups:history` | Read public / private channel messages |
| `channels:read` / `groups:read` | Resolve channel names and info |
| `channels:join` | Auto-join public channels during setup |
| `im:history` | Direct messages (`message.im`) |
| `chat:write` | Post messages and thread replies |
| `reactions:write` | Status reactions (👀 ✅ ❌) |
| `files:write` | Upload files to threads |

Message events (delivered over the socket): `message.channels`, `message.groups`, `message.im`.

Two tokens are involved: the **bot** token (`xoxb-`) does all Slack Web API work (reading history, posting, reactions, uploads); the **app-level** token (`xapp-`) only authorizes the Socket Mode websocket connection.

## Environment Variables

`SlackClaw.setup()` writes these to `slackclaw.env` — `source` it before running. All three are **required**:

```bash
export SLACK_BOT_TOKEN="xoxb-..."     # Bot User OAuth token (Web API)
export SLACK_APP_TOKEN="xapp-..."     # App-level token (Socket Mode connection)
export SLACK_CHANNEL_ID="C0123456789" # Channel to monitor
```

## Quick Start

```julia
using SlackClaw

# Blocking — runs until Ctrl-C
run_monitor(SlackClawConfig(repo_dir = "/path/to/your/repo"))
```

With explicit options:

```julia
run_monitor(SlackClawConfig(
    repo_dir = "/home/user/myproject",
    model = "sonnet",
    max_budget_usd = 1.0,
    max_concurrent_tasks = 3,
))
```

Serve **many channels of one workspace over a single socket** (the right shape for a whole workspace — see [one socket per workspace](#one-socket-per-workspace)):

```julia
bot = ENV["SLACK_BOT_TOKEN"]; app = ENV["SLACK_APP_TOKEN"]

run_socket_fleet([
    SlackClawConfig(slack_bot_token=bot, app_token=app,
                    slack_channel_id="C_REPO_A", repo_dir="/path/to/repo-a"),
    SlackClawConfig(slack_bot_token=bot, app_token=app,
                    slack_channel_id="C_REPO_B", repo_dir="/path/to/repo-b"),
])
```

Embedding (non-blocking): `start_monitor` builds the state (authenticate, load persisted state, post the banner) without looping; drive the loop yourself.

```julia
state = start_monitor(SlackClawConfig())
@async SlackClaw.socket_loop!(state)
# ... later ...
stop_monitor!(state)   # signals shutdown and drains in-flight tasks, but does not
                       # force the socket closed — the loop exits at the next frame
                       # or reconnect, so stopping an idle socket is not instant
```

## Configuration

All options are fields on `SlackClawConfig`:

| Field | Default | Description |
|-------|---------|-------------|
| `slack_bot_token` | `ENV["SLACK_BOT_TOKEN"]` | Bot OAuth token (`xoxb-`) |
| `slack_channel_id` | `ENV["SLACK_CHANNEL_ID"]` | Channel to monitor |
| `app_token` | `get(ENV, "SLACK_APP_TOKEN", "")` | **Required.** App-level `xapp-` token (`connections:write`) |
| `reconcile_interval_s` | `300` | Seconds between gap-fill reconciliation polls |
| `poll_interval_s` | `10` | Background housekeeping cadence (scheduled/proactive checks, reconcile tick) |
| `repo_dir` | `pwd()` | Working directory for Claude |
| `model` | `""` (CLI default) | Claude model name |
| `max_budget_usd` | `0.0` (no limit) | Budget cap per invocation |
| `claude_timeout_s` | `3600` | Max seconds per Claude call |
| `max_turns` | `30` | Max agent turns per invocation |
| `max_concurrent_tasks` | `5` | Parallel Claude invocations |
| `max_active_threads` | `3` | Tracked thread sessions (oldest expire) |
| `max_thread_idle_s` | `604800` (7 d) | Drop tracked threads idle this long (`0` = never) |
| `max_continue` | `10` | Max consecutive `[CONTINUE]` directives |
| `agent_directives` | `true` | Enable `[CONTINUE]`/`[SCHEDULE]` support |
| `system_prompt` | *(brevity prompt)* | System prompt prepended to each invocation |
| `allowed_tools` | `String[]` | Restrict Claude to specific tools |
| `listen_channel_ids` | `String[]` | Read-only channels (relevance-filtered; responses go to the primary channel) |
| `state_file` | `.slackclaw_state.json` | Persistence file in `repo_dir` (override when channels share a `repo_dir`) |
| `status_file` | `.slackclaw_status` | File watched during execution; its contents post as progress updates |
| `status_poll_s` | `30` | How often to check `status_file` while Claude runs |
| `bot_user_id` | `""` | Bot's own user ID (auto-filled at startup; used to skip self-messages) |
| `proactive_enabled` | `false` | Enable periodic autonomous checks |
| `proactive_prompt` | `""` | Inline suggestions for proactive actions |
| `proactive_interval_s` | `3600` | Seconds between proactive checks |

## How It Works

1. **Receive** — Slack pushes each new message over the websocket; SlackClaw acks immediately and enqueues it.
2. **Dispatch** — each message spawns an async Claude invocation in the configured `repo_dir`.
3. **React** — emoji reactions track status: 👀 (processing), ✅ (success), ❌ (error).
4. **Thread** — all responses go to the message thread, preserving conversation context; long responses split across multiple messages.
5. **Resume** — replies in a thread continue the same Claude session via `--resume`.
6. **Listen** — messages from listen channels are relevance-filtered (irrelevant ones silently skipped) and posted to the primary channel.
7. **Proactive** — periodically runs autonomous checks and posts only when something is noteworthy.
8. **Persist** — sessions, scheduled tasks, and proactive timestamps survive restarts (`.slackclaw_state.json`).

### Delivery and reliability

SlackClaw opens an outbound websocket (`apps.connections.open`, authorized by the app-level token) and Slack pushes message events as they happen — sub-second latency, no public endpoint (works behind firewalls/NAT), and listen channels arrive on the same socket (the periodic reconciliation still backfills each one's history). Replies always go out over the bot token (`chat.postMessage`); the socket is events-in only.

Push delivery is **at-least-once with gaps** — events that fire while the connection is down are not replayed. SlackClaw keeps message cursors as a safety net: a **reconciliation poll** fetches anything newer than the cursors on every (re)connect and every `reconcile_interval_s` (default 5 min), and every message — socket or reconcile — claims its cursor exactly once before dispatch, so the two paths and any Slack redeliveries can overlap without ever double-dispatching.

**Connection lifecycle.** Slack refreshes Socket Mode connections every few hours by design: a `disconnect` `warning` arrives ~1 min ahead (SlackClaw keeps serving), then `refresh_requested`; SlackClaw requests a fresh URL and reconnects (immediate when healthy, exponential backoff while failing). Each pushed envelope is acked on receipt — before Claude is dispatched — because unacked envelopes are redelivered after ~3 s while Claude runs for minutes.

See [`docs/src/socket-mode.md`](docs/src/socket-mode.md) for the full event-flow and troubleshooting reference.

### One socket per workspace

Slack load-balances events across an app's open sockets — each event goes to exactly **one** of them. So a workspace must be served by exactly one connection. For multiple channels, do **not** run one socket monitor per channel under the same app (they'd each see a random subset and miss the rest) — run a single [`run_socket_fleet`](#quick-start) process that serves them all over one socket. Separate workspaces get separate apps and token sets.

### Agent Directives

When `agent_directives` is enabled (default), Claude can control its own execution flow:

- **`[CONTINUE]`** — immediately re-invoke in the same session for multi-step work
- **`[CONTINUE: next step description]`** — re-invoke with a specific follow-up prompt
- **`[SCHEDULE: 2h: check pipeline results]`** — schedule a future invocation (`30m`, `1h`, `2h30m`, …)

If no directive is present, the task is complete.

### Multi-Channel Listening

A monitor can listen to additional channels beyond its primary one. Messages from listen channels are posted as new threads in the primary channel (prefixed with the source channel name) and processed there:

```julia
run_monitor(SlackClawConfig(
    slack_channel_id = "C_PRIMARY",
    listen_channel_ids = ["C_GENERAL", "C_ANNOUNCE"],
    repo_dir = "/path/to/repo",
))
```

The bot must be a member of each listen channel. Channel names are resolved on startup and cached. A relevance filter runs first: Claude is asked whether each message is relevant to the instance's repo/role before posting, and irrelevant messages are silently dropped.

### Proactive Mode

When enabled, SlackClaw periodically runs Claude to autonomously check for things worth reporting — but only once it has an agenda: it fires only when `.slackclaw_proactive_tasks` exists in `repo_dir` (or `proactive_prompt` is set). Claude reads two files in `repo_dir` at runtime:

- **`.slackclaw_proactive_tasks`** — what to check (task suggestions). Editable anytime without restart.
- **`.slackclaw_proactive_log`** — what was already reported (auto-appended). Gives Claude context to avoid repeats.

If nothing is noteworthy, Claude responds `[SKIP]` and stays silent.

```julia
run_monitor(SlackClawConfig(
    proactive_enabled = true,
    proactive_interval_s = 3600,        # check every hour
))
```

Task suggestions go in `.slackclaw_proactive_tasks` (created by an orchestrator or by hand):

```
- Check for open PRs that need review
- Summarize notable recent commits
- Check if any CI pipelines are failing
```

Frequency can be adjusted live via Slack messages in the monitored channel:

- `proactive every 30m` — change interval
- `proactive off` / `proactive on` — toggle

### Progress updates during long tasks

While Claude runs, SlackClaw watches `status_file` (`.slackclaw_status` in `repo_dir`, polled every `status_poll_s`). Any non-empty content present when it polls is posted to the thread as a progress update (a value overwritten between polls can be missed), then the file is cleared when the task finishes. This lets a long-running task narrate itself.

## Running as a Service

A tmux session or systemd unit works well. Serve a whole workspace with one fleet process:

```bash
tmux new -s slackclaw
source slackclaw.env          # SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_CHANNEL_ID
julia --project=/path/to/SlackClaw examples/fleet.jl
```

One Slack app == one socket == one process per workspace. For a second workspace, use its own app and token set and run a second process.
