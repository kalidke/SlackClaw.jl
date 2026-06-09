# Slack App Setup

Everything SlackClaw needs on the Slack side: a bot token with the right
scopes, a channel to watch, and — only for Socket Mode — an app-level token
plus event subscriptions.

## 1. Create the app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
2. Name it (e.g. `SlackClaw`) and pick the workspace.

## 2. Bot token scopes

Under **OAuth & Permissions → Bot Token Scopes** add:

| Scope | Purpose |
|-------|---------|
| `channels:history` | Read messages in public channels |
| `channels:read` | Resolve channel names (listen channels) |
| `groups:history` | Read messages in private channels |
| `chat:write` | Post messages and thread replies |
| `reactions:write` | Status reactions (👀 ✅ ❌) |

## 3. Install and collect tokens

1. **Install App → Install to Workspace**, authorize.
2. Copy the **Bot User OAuth Token** (`xoxb-...`) → `SLACK_BOT_TOKEN`.

```bash
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_CHANNEL_ID="C0123456789"   # step 5 below
export SLACK_APP_TOKEN="xapp-..."       # only for Socket Mode (step 4)
```

## 4. Socket Mode (optional, push delivery)

Skip if you only need polling. Three app-side switches, all required:

1. **Socket Mode** (sidebar) → toggle **Enable Socket Mode**. Create the
   prompted **app-level token** with scope `connections:write`; copy it
   (`xapp-...`) → `SLACK_APP_TOKEN`.

   !!! note "Three token types"
       The app-level `xapp-` token only authorizes the websocket connection.
       It is not a bot token: replies, reactions, and uploads still use
       `SLACK_BOT_TOKEN`. Bot tokens (`xoxb-`) cannot open Socket Mode
       connections (`not_allowed_token_type`).

2. **Event Subscriptions** → **Enable Events** → **Subscribe to bot events**:

   | Event | Delivers | Required bot scope |
   |-------|----------|--------------------|
   | `message.channels` | Public-channel messages | `channels:history` (already added) |
   | `message.groups` | Private-channel messages | `groups:history` (already added) |
   | `message.im` | Direct messages (optional) | `im:history` (add it if you subscribe) |

   Without these the websocket connects but never receives a message event.

3. **Reinstall** the app when Slack prompts (any scope/event change requires
   it): **Install App → Reinstall to Workspace**.

## 5. Wire up a channel

1. In the target channel: `/invite @SlackClaw`.
2. Channel ID: right-click the channel name → **View channel details** → the
   ID (`C0123456789`) is at the bottom → `SLACK_CHANNEL_ID`.

## Multiple channels and workspaces

- **Polling**: run one monitor instance per channel/repo pair (same bot token,
  different `slack_channel_id`/`repo_dir`). Instances share nothing else.
- **Socket Mode**: at most **one** socket monitor per workspace app — Slack
  load-balances each event to exactly one open socket, so parallel socket
  instances would each see only a random subset. Extra per-channel instances
  must stay on polling.
- **Separate workspaces** get separate apps and token sets (e.g.
  `SLACK_BOT_TOKEN_KAL` / `SLACK_BOT_TOKEN_ATQI` resolved per instance).

## Verify

Start a monitor; it posts `_SlackClaw monitor started_` to the channel with
its configuration summary (the banner includes `Socket Mode` when push is
active). Post a message in the channel — within ~1 s (socket) or one poll
interval (polling) the bot reacts with 👀 and replies in a thread.
