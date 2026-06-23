```@meta
CurrentModule = SlackClaw
```

# Socket Mode (Push Delivery)

SlackClaw receives messages over Slack Socket Mode: it opens an outbound
websocket to Slack ([`apps.connections.open`](https://api.slack.com/apis/socket-mode))
and Slack pushes message events as they happen. This is the only *live*
delivery mechanism — there is no polling mode to enable or disable (a
low-frequency reconciliation still backfills history; see Reliability below).

**Why Socket Mode:**

- Sub-second latency — events are pushed, not polled.
- No *continuous* history polling — only a low-frequency reconciliation fetch
  (every `reconcile_interval_s`), so rate-limit pressure is minimal.
- Listen channels ride the same socket: every channel the bot is in arrives on
  one connection (the reconciliation poll still backfills each one's history).
- No public endpoint is needed (unlike the HTTP Events API): the connection is
  outbound-only, so it works behind firewalls and NAT.

**Prerequisites** (the [`setup()`](setup.md) wizard provisions all of these): an
app-level `xapp-` token with `connections:write` in `SLACK_APP_TOKEN`, Socket
Mode enabled on the app, and the `message.*` event subscriptions. A missing or
empty `app_token` is a startup error.

## Usage

```julia
using SlackClaw

run_monitor(SlackClawConfig(
    repo_dir = "/path/to/repo",
    app_token = ENV["SLACK_APP_TOKEN"],   # default; shown for clarity
    reconcile_interval_s = 300,           # gap-fill reconciliation cadence (default 5 min)
))
```

Everything downstream of message receipt — dispatching, threading, directives,
listen-channel relevance filtering, proactive checks, persistence — is the same
regardless of how a message arrived (a live socket event or the reconciliation
poll). Replies go out over the bot token (`chat.postMessage`); the socket is
events-in only.

## How it works

### Event flow

1. `apps.connections.open` (authenticated with the app-level token) returns a
   short-lived `wss://` URL; SlackClaw connects with `HTTP.WebSockets`.
2. Slack pushes each event wrapped in an envelope. The websocket read loop does
   three things only — parse, **ack immediately**, enqueue — and never touches
   the Slack Web API. Slack redelivers envelopes not acked within ~3 s, so any
   blocking work in the read loop (even a single rate-limit retry sleep) would
   starve the acks of frames queued behind it.
3. A single FIFO consumer task drains the queue: each event is classified
   (top-level message in the primary channel, reply in a tracked thread,
   listen-channel message, or ignorable) and routed into the dispatch
   functions. The consumer stays single deliberately: cursor claims rely on
   per-channel timestamp ordering, and an out-of-order claim would advance a
   cursor past an undispatched message — a loss reconciliation could never
   detect. Claude invocations themselves still fan out to the concurrent task
   pool inside dispatch.

### Reliability: reconciliation and cursors

Push delivery is at-least-once, and events that fire while the connection is
down are **not** replayed by Slack. SlackClaw keeps message cursors as a safety
net:

- A **reconciliation poll** — a full history fetch of anything newer than the
  cursors (primary channel, tracked threads, listen channels) — fires on every
  (re)connect and every `reconcile_interval_s` (default 300 s).
- Every message, from either path, must **claim its cursor** (primary-channel
  `last_ts`, per-thread `last_reply_ts`, or per-listen-channel cursor) under a
  lock before dispatch. First claim wins; replays lose.

The result: socket events, reconciliation fetches, and Slack redeliveries can
overlap freely and a message is still dispatched exactly once.

### Connection lifecycle

Slack refreshes Socket Mode connections every few hours by design:

- A `disconnect` frame with reason `warning` arrives ~1 min ahead — SlackClaw
  keeps serving.
- On `refresh_requested` (or any close/error), SlackClaw requests a fresh URL
  and reconnects — immediate after a healthy connection, exponential backoff
  (capped at 60 s) while connections are failing.
- Each successful (re)connect triggers a reconciliation poll to fill whatever
  gap the downtime left.

Scheduled tasks (`[SCHEDULE]` directives) and proactive checks are time-driven,
not event-driven; a background housekeeping task fires them on the
`poll_interval_s` cadence.

### One socket per workspace

Slack load-balances events across an app's open Socket Mode connections — each
event is delivered to exactly **one** of them. Two SlackClaw socket monitors
under the same app would each receive a random half of the traffic. Serve a
whole workspace from a single connection — use `run_socket_fleet` below for
multiple channels, and give separate workspaces separate apps.

### Serving a whole workspace: `run_socket_fleet`

To run *all* of a workspace's channels on push, use the fleet entry point —
many channels, one socket, one process:

```julia
bot = ENV["SLACK_BOT_TOKEN"]; app = ENV["SLACK_APP_TOKEN"]

configs = [SlackClawConfig(slack_bot_token=bot, app_token=app,
                           slack_channel_id=id, repo_dir=dir)
           for (id, dir) in channels]
run_socket_fleet(configs)
```

Each config keeps its own monitor state — threads, persistence, scheduled
tasks, proactive checks, and budgets behave exactly as in a single-channel
monitor — and every pushed event is offered to every state, which ignores
channels it doesn't serve. Startup validation requires: identical bot and app
tokens across the fleet (one fleet = one workspace), unique primary channels,
and unique state-file paths — fleet startup **errors** if two channels resolve
to the same `state_file`, so channels sharing a `repo_dir` must each set a
distinct one (a shared `status_file` is allowed but warns, since status updates
could cross-post). (`run_monitor` for a single channel is just a fleet of one.)

## Configuration reference

| Field | Default | Description |
|-------|---------|-------------|
| `app_token` | `get(ENV, "SLACK_APP_TOKEN", "")` | **Required.** App-level `xapp-` token, scope `connections:write` |
| `reconcile_interval_s` | `300` | Seconds between gap-fill reconciliation polls |
| `poll_interval_s` | `10` | Cadence of the housekeeping task (scheduled/proactive checks, reconcile tick) |

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `not_allowed_token_type` on connect | `app_token` is a bot (`xoxb-`) token — use the app-level `xapp-` token |
| `invalid_auth` on connect | App-level token revoked, or belongs to a different app |
| `app_token is empty` at startup | `SLACK_APP_TOKEN` not set in the monitor's environment |
| Connects (`Socket Mode connected` logged) but never reacts to messages | Event subscriptions missing, or app not reinstalled after adding them |
| Some messages handled, others silently missed | A second Socket Mode connection is open for the same app — events are being split |
| Bot deaf in one channel only | Bot not a member — `/invite @SlackClaw` there |
| Messages handled twice | Should not happen (cursor claims); check that two monitors aren't watching the same channel with different `repo_dir` state files |
```
