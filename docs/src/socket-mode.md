```@meta
CurrentModule = SlackClaw
```

# Socket Mode (Push Delivery)

With `socket_mode = true`, SlackClaw stops polling `conversations.history` on
a timer and instead opens an outbound websocket to Slack
([`apps.connections.open`](https://api.slack.com/apis/socket-mode)); Slack
pushes message events as they happen.

**Why:**

- Latency drops from ~10 s average (half the poll interval) to sub-second.
- Per-channel history polling — and the rate-limit pressure and staggering it
  required — disappears.
- Listen channels become free: every channel the bot is in arrives on the same
  socket, and routing is a local decision.
- No public endpoint is needed (unlike the HTTP Events API): the connection is
  outbound-only, so it works behind firewalls and NAT.

**Prerequisites** (details in [Slack App Setup](setup.md), step 4): Socket Mode
enabled on the app, an app-level `xapp-` token with `connections:write` in
`SLACK_APP_TOKEN`, message event subscriptions added, app reinstalled.

## Usage

```julia
using SlackClaw

run_monitor(SlackClawConfig(
    socket_mode = true,
    app_token = ENV["SLACK_APP_TOKEN"],   # default; shown for clarity
    repo_dir = "/path/to/repo",
    reconcile_interval_s = 300,           # gap-fill poll cadence (default 5 min)
))
```

Mode selection is explicit: `socket_mode = true` with an empty `app_token` is
a startup error. SlackClaw never silently falls back to polling, so a
misconfigured push instance cannot degrade into an unexpected polling load.

Everything downstream of message receipt is identical to polling mode —
dispatching, threading, directives, listen-channel relevance filtering,
proactive checks, persistence. Replies go out over the bot token
(`chat.postMessage`); Socket Mode is events-in only.

## How it works

### Event flow

1. `apps.connections.open` (authenticated with the app-level token) returns a
   short-lived `wss://` URL; SlackClaw connects with `HTTP.WebSockets`.
2. Slack pushes each event wrapped in an envelope. The websocket read loop
   does three things only — parse, **ack immediately**, enqueue — and never
   touches the Slack Web API. Slack redelivers envelopes not acked within
   ~3 s, so any blocking work in the read loop (even a single rate-limit
   retry sleep) would starve the acks of frames queued behind it.
3. A single FIFO consumer task drains the queue: each event is classified
   (top-level message in the primary channel, reply in a tracked thread,
   listen-channel message, or ignorable) and routed into the same dispatch
   functions polling mode uses. The consumer stays single deliberately:
   cursor claims rely on per-channel timestamp ordering, and an out-of-order
   claim would advance a cursor past an undispatched message — a loss
   reconciliation could never detect. Claude invocations themselves still
   fan out to the concurrent task pool inside dispatch.

### Reliability: reconciliation and cursors

Push delivery is at-least-once, and events that fire while the connection is
down are **not** replayed by Slack. SlackClaw keeps the polling cursor
machinery as a safety net rather than discarding it:

- A **reconciliation poll** — the exact message-fetch pass polling mode runs —
  fires on every (re)connect and every `reconcile_interval_s` (default 300 s),
  fetching anything newer than the cursors.
- Every message, from either path, must **claim its cursor** (primary-channel
  `last_ts`, per-thread `last_reply_ts`, or per-listen-channel cursor) under a
  lock before dispatch. First claim wins; replays lose.

The result: socket events, reconciliation fetches, and Slack redeliveries can
overlap freely and a message is still dispatched exactly once. Disk state
(`.slackclaw_state.json`) is shared between modes, so switching a channel
between polling and Socket Mode is just flipping the flag and restarting.

### Connection lifecycle

Slack refreshes Socket Mode connections every few hours by design:

- A `disconnect` frame with reason `warning` arrives ~1 min ahead — SlackClaw
  keeps serving.
- On `refresh_requested` (or any close/error), SlackClaw requests a fresh URL
  and reconnects — immediate after a healthy connection, exponential backoff
  (capped at 60 s) while connections are failing.
- Each successful (re)connect triggers a reconciliation poll to fill whatever
  gap the downtime left.

Scheduled tasks (`[SCHEDULE]` directives) and proactive checks are
time-driven, not event-driven; a background housekeeping task keeps firing
them on the same cadence as polling mode.

### One socket per workspace

Slack load-balances events across an app's open Socket Mode connections —
each event is delivered to exactly **one** of them. Two SlackClaw socket
monitors under the same app would each receive a random half of the traffic.
Run a single Socket Mode monitor per workspace app; additional per-channel
instances must use polling.

### Serving a whole workspace: `run_socket_fleet`

To run *all* of a workspace's channels on push, use the fleet entry point —
many channels, one socket, one process:

```julia
configs = [SlackClawConfig(slack_channel_id=id, socket_mode=true,
                           repo_dir=dir, ...) for (id, dir) in channels]
run_socket_fleet(configs)
```

Each config keeps its own monitor state — threads, persistence, scheduled
tasks, proactive checks, and budgets behave exactly as in a single-channel
monitor — and every pushed event is offered to every state, which ignores
channels it doesn't serve. Startup validation requires: identical bot and app
tokens across the fleet (one fleet = one workspace), `socket_mode = true` on
every config, unique primary channels, and unique state-file paths — two
channels sharing a `repo_dir` must set distinct `state_file` values, since a
shared state file is silently last-writer-wins.

## Configuration reference

| Field | Default | Description |
|-------|---------|-------------|
| `socket_mode` | `false` | Enable push delivery |
| `app_token` | `get(ENV, "SLACK_APP_TOKEN", "")` | App-level `xapp-` token, scope `connections:write` |
| `reconcile_interval_s` | `300` | Seconds between gap-fill reconciliation polls |
| `poll_interval_s` | `10` | In socket mode: cadence of the housekeeping task (scheduled/proactive checks) |

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `not_allowed_token_type` on connect | `app_token` is a bot (`xoxb-`) token — use the app-level `xapp-` token |
| `invalid_auth` on connect | App-level token revoked, or belongs to a different app |
| `socket_mode=true but app_token is empty` at startup | `SLACK_APP_TOKEN` not set in the monitor's environment |
| Connects (`Socket Mode connected` logged) but never reacts to messages | Event subscriptions missing, or app not reinstalled after adding them |
| Some messages handled, others silently missed | A second Socket Mode connection is open for the same app — events are being split |
| Bot deaf in one channel only | Bot not a member — `/invite @SlackClaw` there |
| Messages handled twice | Should not happen (cursor claims); check that two monitors aren't watching the same channel with different `repo_dir` state files |
