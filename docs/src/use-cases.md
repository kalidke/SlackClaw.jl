```@meta
CurrentModule = SlackClaw
```

# Use Cases

Each use case below is set up once on a channel's monitor. Do the one-time
[Slack App Setup](setup.md) first and `source slackclaw.env`; the examples then
assume `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` / `SLACK_CHANNEL_ID` are set. Every
config field shown is per-channel — in a [`run_socket_fleet`](socket-mode.md)
deployment, set the same fields on each member config.

## Fix a bug or add a feature

Post a request in the channel; Claude works in the repo and replies in the thread.

**Setup** — point a monitor at the repo:

```julia
run_monitor(SlackClawConfig(repo_dir = "/path/to/repo", model = "sonnet"))
```

Claude has full tool access in `repo_dir` (it can edit files and run the tests),
but it does **not** commit on its own. To make commits part of the workflow,
append a policy to the system prompt (the field is mutable, so you keep the
default Slack-formatting prompt):

```julia
cfg = SlackClawConfig(repo_dir = "/path/to/repo")
cfg.system_prompt *= "\n\nCommit your changes with a clear message before replying."
run_monitor(cfg)
```

**Use it** — in the channel: *"Fix the off-by-one in `parse_header` and add a test."*
Reply in the thread to iterate; the same Claude session is resumed.

## Get a plot back as an image

Claude generates a figure and posts it to the thread.

**Setup:**

- Provision with [`SlackClaw.setup()`](setup.md) — its manifest already includes
  the `files:write` scope. (Apps created before v0.4.0 must add `files:write`
  and reinstall.)
- Install `curl` and `jq` on the host (the upload helper uses them).

Nothing else is needed: `bin/slack-upload` ships with the package, and SlackClaw
appends an upload instruction to the system prompt automatically whenever a
message is dispatched in a thread.

**Use it** — *"Plot the loss curve from `logs/run42.csv` and send it back."*
Claude saves an image and runs `$SLACKCLAW_UPLOAD <file>` under the hood.

## Periodically scan your repos

On a schedule, Claude runs the checks you define and posts only when there's
something worth flagging.

**Setup** — enable proactive mode and set the interval:

```julia
run_monitor(SlackClawConfig(
    repo_dir = "/path/to/repo",
    proactive_enabled = true,
    proactive_interval_s = 14400,     # every 4 h
))
```

Then write the checks to `.slackclaw_proactive_tasks` in `repo_dir` (plain text,
editable anytime — it's re-read each cycle):

```
- List open PRs that need review
- Report any failing CI runs
- Flag branches with no commits in 30+ days
```

Proactive mode fires only when this file exists (or `proactive_prompt` is set).
SlackClaw appends a summary of each post to `.slackclaw_proactive_log`, which
Claude reads for context to avoid repeats. Adjust live from the channel:
`proactive every 2h`, `proactive off`, `proactive on`.

## Kick off a long job and walk away

Claude starts a long task, optionally posts progress, and schedules a follow-up.

**Setup** — `agent_directives` is on by default, so Claude can end a reply with
`[SCHEDULE: 2h: check the run and report results]` to be re-invoked later. For
live progress, tell Claude to write to the status file — SlackClaw polls it every
`status_poll_s` and posts changes to the thread:

```julia
cfg = SlackClawConfig(repo_dir = "/path/to/repo")
cfg.system_prompt *= "\n\nFor long tasks, write one-line progress updates to " *
                     ".slackclaw_status in your working directory."
run_monitor(cfg)
```

**Use it** — *"Start the training run; post progress and tell me when it's done."*

## Triage across repos from one channel

Post in a shared hub channel; each repo's monitor answers only if the message is
relevant to it.

**Setup** — invite the bot to the hub channel, then serve the workspace's repo
channels from one socket with [`run_socket_fleet`](socket-mode.md), giving each
member the hub in its `listen_channel_ids`:

```julia
bot = ENV["SLACK_BOT_TOKEN"]; app = ENV["SLACK_APP_TOKEN"]

run_socket_fleet([
    SlackClawConfig(slack_bot_token=bot, app_token=app, slack_channel_id="C_REPO_A",
                    repo_dir="/repo/a", listen_channel_ids=["C_HUB"]),
    SlackClawConfig(slack_bot_token=bot, app_token=app, slack_channel_id="C_REPO_B",
                    repo_dir="/repo/b", listen_channel_ids=["C_HUB"]),
])
```

Use the fleet, not one `run_monitor` per repo: a workspace's events are
load-balanced across an app's open sockets, so separate per-channel monitors
under one app would each see only a subset (separate workspaces get separate
apps). Each hub message runs through a relevance filter — only the repos it's
relevant to reply, each posting a new thread in its **own** channel.

**Use it** — in the hub: *"Anyone's tests failing after the JSON bump?"* Only the
affected repos respond, each in its own channel.

## Ask about a codebase

Ask a question; Claude reads the repo and explains — from your phone, no terminal.

**Setup** — just a monitor on the repo channel; nothing extra.

**Use it** — *"How does the reconciliation loop avoid double-dispatch?"*
