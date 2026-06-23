```@meta
CurrentModule = SlackClaw
```

# Slack App Setup

SlackClaw provisions its own Slack app. The wizard automates everything that an
API can do and groups the human-only steps into a single browser session, so
setup is **generate → (do the browser steps once) → verify**, with no
back-and-forth.

```julia
using SlackClaw
SlackClaw.setup()
```

## What you do vs. what the wizard does

Only three things genuinely require a human, and they are contiguous in the
Slack web UI:

1. **Create the app from the manifest.** At [api.slack.com/apps](https://api.slack.com/apps)
   → **Create New App** → **From an app manifest** → pick the workspace → paste
   the manifest the wizard printed → **Create**. The manifest pre-sets every bot
   scope, the message-event subscriptions, and Socket Mode — there is nothing to
   toggle by hand.
2. **Install to workspace.** **Install App** → **Install to Workspace** →
   **Allow**, then copy the **Bot User OAuth Token** (`xoxb-…`).
3. **Mint the app-level token.** **Basic Information** → **App-Level Tokens** →
   **Generate Token and Scopes** → add `connections:write` → **Generate**, then
   copy the token (`xapp-…`).

One extra step only for a **private** channel: `/invite @SlackClaw` in it.
Public channels are joined automatically.

Paste the two tokens and the channel name/ID back into the wizard. From there it
is automated — the wizard:

- validates the bot token (`auth.test`) and reports the workspace,
- resolves the channel name to its ID,
- **auto-joins** the channel if it is public and the bot isn't a member,
- runs a **live Socket Mode self-test** with the app token (opens the websocket
  and waits for Slack's `hello`),
- writes a gitignored `slackclaw.env` (`chmod 600`) with the three values,
- posts a confirmation to the channel,
- prints a pass/fail checklist and the command to start the monitor.

## The manifest

```julia
println(SlackClaw.generate_manifest())
```

The bot scopes and events it requests, and why:

| Bot scope | Purpose |
|-----------|---------|
| `channels:history` / `groups:history` | Read public / private channel messages |
| `channels:read` / `groups:read` | Resolve channel names and info |
| `channels:join` | Auto-join public channels during setup |
| `im:history` | Direct messages (`message.im`) |
| `chat:write` | Post messages and thread replies |
| `reactions:write` | Status reactions (👀 ✅ ❌) |
| `files:write` | Upload files to threads |

Message events (delivered over the socket): `message.channels`,
`message.groups`, `message.im`.

!!! note "Two token types"
    The **bot** token (`xoxb-`) does all Slack Web API work — reading history,
    posting replies, reactions, uploads. The **app-level** token (`xapp-`, scope
    `connections:write`) only authorizes the Socket Mode websocket; it cannot
    call Web API methods, and a bot token cannot open a socket
    (`not_allowed_token_type`).

## Non-interactive setup

For scripted or CI use, drive the two halves directly instead of the wizard:

```julia
# 1. Print the manifest to create the app from.
println(SlackClaw.generate_manifest(; app_name = "SlackClaw"))

# 2. After creating/installing the app and minting the app token, verify & wire:
SlackClaw.verify_setup(;
    bot_token = "xoxb-…",
    app_token = "xapp-…",
    channel   = "#dev",        # name or ID
    write_env = true,          # write slackclaw.env (default)
    announce  = true,          # post a confirmation to the channel (default)
)
```

`verify_setup` returns `(; ok, channel_id, bot_user_id, team, checks)` and is
safe to re-run.

## Multiple channels and workspaces

- **Many channels, one workspace:** run a single
  [`run_socket_fleet`](socket-mode.md) process. Slack delivers each event to
  exactly one of an app's open sockets, so
  the whole workspace must share one connection — do not run a separate socket
  monitor per channel under the same app.
- **Separate workspaces** get separate apps and token sets (e.g.
  `SLACK_BOT_TOKEN_KAL` / `SLACK_BOT_TOKEN_ATQI` resolved per process). Run
  `setup()` once per workspace.

## Verify

The wizard's self-test already confirms the chain end to end. To check a running
monitor, start it: it posts `_SlackClaw monitor started_` to the channel with a
configuration summary. Post a message — within ~1 s the bot reacts with 👀 and
replies in a thread.
```
