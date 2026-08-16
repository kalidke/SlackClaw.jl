```@meta
CurrentModule = SlackClaw
```

# Features

All features are toggles or fields on [`SlackClawConfig`](@ref). Defaults are in
the [configuration table](https://github.com/kalidke/SlackClaw.jl#configuration).

## Agent directives

When `agent_directives` is enabled (default), Claude can control its own
execution flow by ending a response with a directive:

- **`[CONTINUE]`** — immediately re-invoke in the same session for multi-step work.
- **`[CONTINUE: next step description]`** — re-invoke with a specific follow-up prompt.
- **`[SCHEDULE: 2h: check pipeline results]`** — queue a future invocation;
  durations accept `30m`, `1h`, `2h30m`, and the like.

If no directive is present the task is complete. Consecutive `[CONTINUE]`s are
capped at `max_continue` (default 10) as a runaway guard; scheduled tasks
survive restarts via `.slackclaw_state.json`.

## Multi-channel listening

A monitor can listen to channels beyond its primary one. Set `listen_channel_ids`:

```julia
run_monitor(SlackClawConfig(
    slack_channel_id   = "C_PRIMARY",
    listen_channel_ids = ["C_GENERAL", "C_ANNOUNCE"],
    repo_dir           = "/path/to/repo",
))
```

Messages from listen channels run through a **relevance filter** first: Claude
is asked whether the message is relevant to this instance's repo/role and
answers `[SKIP]` if not. The check is a **containment** match (`[SKIP]`
anywhere in the reply): models reliably narrate their verdict and leave the
token at the end, and a stricter check would post that narration as spam —
here a false positive only suppresses an optional post.
Only relevant messages are posted — as a new thread in
the **primary** channel, prefixed with the sender and source channel name — and
handled there. The bot must be a member of each listen channel; channel names are
resolved on startup and cached. Listen-channel events arrive live on the same
socket as the primary channel; the only extra cost is that the periodic
reconciliation also backfills each listen channel's history.

## Sender attribution

Every user message reaches Claude prefixed with its authenticated Slack sender:

```
[from <@U0123ABCDE>]

<the user's message>
```

on the primary/thread paths, and inline — `[from <@U0123ABCDE> in #general] …` —
on the listen path. The sender comes from the Slack event's `user` field, not
from anything typed in the message, and the prefix is unconditional (no config
toggle). It exists so a channel's `system_prompt` can enforce per-user
authorization rules ("only run deploys when the requester is `<@U…>`") and
record who asked for each action — neither is possible if the authenticated
sender never reaches Claude.

Only the **first** `[from …]` line of a prompt is authoritative. A user can
type a forged `[from …]` line at the start of their message, so SlackClaw
neutralizes any leading `[from …]`-shaped lines in the user text (they become
`user wrote: [from …]`) before attaching the real prefix — the forgery stays
visible, but cannot pose as the attribution. Messages without a `user` field
are attributed `[from unknown]`, which fail-closed authorization prompts
should reject.

## Declining to answer (`allow_skip`)

In a shared channel full of people, teammate-like behavior means answering when
useful and staying out of exchanges aimed at other people. With
`allow_skip = true`, a reply of exactly `[SKIP]` on the primary/thread path
posts nothing and adds no checkmark (the thread's Claude session is still
tracked, so later in-thread replies keep continuity). The match is **exact**
(`strip(text) == "[SKIP]"`), stricter than the containment match on the
listen/proactive filters — on this path a false positive would swallow a real
answer in the user's own channel. This is only the mechanism: instruct Claude *when* to skip via
`system_prompt`. To help it tell when it was tagged, mentions of the bot itself
reach Claude as `@you` instead of a raw `<@U…>` ID.

The 👀 reaction doubles as an intent signal on `allow_skip` channels: eyes go
on at dispatch (as on every channel), and come back **off** when the reply is
`[SKIP]`. Lingering eyes mean a reply is coming; vanished eyes mean the bot saw
the message and is deliberately staying out. Failures to remove the reaction
(deleted message, manual un-react race) are swallowed — an un-react is always
benign. Default **off** — existing deployments behave as before.

## Proactive mode

When `proactive_enabled = true`, SlackClaw periodically runs Claude to check for
things worth reporting (every `proactive_interval_s`, default 1 h) — but only
once it has an agenda: it fires only when `.slackclaw_proactive_tasks` exists in
`repo_dir` (or `proactive_prompt` is set). Claude reads two files in `repo_dir`
at runtime:

- **`.slackclaw_proactive_tasks`** — what to check. Editable anytime without a
  restart, so you can adjust the agenda live.
- **`.slackclaw_proactive_log`** — what was already reported (auto-appended).
  Claude reads it to avoid repeating itself.

If nothing is noteworthy, Claude responds `[SKIP]` and stays silent; only real
content is posted as a top-level message in the primary channel. As on the
listen path, the check is a **containment** match — a narrated decline
("checked everything, nothing new. `[SKIP]`") is suppressed rather than posted.
A suppressed run's full text is still appended to the log (tagged
`[suppressed]`) so the next cycle's dedup keeps its reasoning.

```julia
run_monitor(SlackClawConfig(
    proactive_enabled    = true,
    proactive_interval_s = 1800,   # every 30 min
))
```

Frequency can be changed live by posting in the monitored channel:

- `proactive every 30m` (or `proactive interval 2h`) — adjust the interval
- `proactive on` / `proactive off` — toggle

The `proactive_prompt` field can carry inline suggestions, but prefer
`.slackclaw_proactive_tasks` so the agenda hot-reloads.

## Progress updates during long tasks

While Claude runs, SlackClaw watches `status_file` (`.slackclaw_status` in
`repo_dir`, polled every `status_poll_s`). Any non-empty content present when it
polls is posted to the thread as a progress update (a value overwritten between
polls can be missed), and the file is cleared when the task finishes — letting a
long task narrate itself rather than going silent.

## Sending files and images

When Claude runs under SlackClaw with an active thread, it can attach a file or
image to its reply. SlackClaw injects `SLACKCLAW_UPLOAD` (the path to the bundled
`bin/slack-upload` helper) plus the thread context (`SLACKCLAW_THREAD_TS`,
`SLACKCLAW_CHANNEL_ID`, `SLACKCLAW_BOT_TOKEN`) into the subprocess environment, and
appends a short instruction to the system prompt telling Claude the helper exists.
So "plot X and send it back" needs no extra wiring: Claude saves the figure and runs
`$SLACKCLAW_UPLOAD <file_path> ["caption"]`, which posts it into the current thread
via Slack's external upload flow (`files.getUploadURLExternal` +
`files.completeUploadExternal`). It needs `curl` and `jq` on the host and the
`files:write` scope — included in the setup manifest, but apps created before this
release must add `files:write` and reinstall.

## Concurrency and thread limits

- Each message is dispatched as an async task; at most `max_concurrent_tasks`
  (default 5) run at once. Messages that arrive while at the cap get a brief
  "busy" reply.
- A busy thread that receives another message reports elapsed time instead of
  starting a second run.
- At most `max_active_threads` (default 3) conversation threads are tracked;
  the oldest are retired first. Threads idle longer than `max_thread_idle_s`
  (default 7 days; `0` disables) are also retired — each tracked thread costs a
  `conversations.replies` call per reconciliation, so this bounds steady load.

## Persistence

State is saved to `state_file` (`.slackclaw_state.json` in `repo_dir`): the
primary cursor, tracked thread sessions, scheduled tasks, per-listen-channel
cursors, and the last proactive timestamp. It is loaded on startup, so sessions
and schedules survive restarts. Channels that share a `repo_dir` must each set a
distinct `state_file`.
```
