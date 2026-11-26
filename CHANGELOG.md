# Changelog

Notable changes to SlackClaw.jl. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses
[Semantic Versioning](https://semver.org/) (pre-1.0, so minor bumps may break).

## [Unreleased] — 0.7.5-DEV

### Security

- **The Claude child gets an allow-listed environment** (issue #11). It
  inherited the monitor's whole environment except the nested-session
  variables, so every run, following prompts any channel member can write,
  held the workspace's app-level token, every other workspace's bot token in
  a fleet's environment, and any other credential the monitor had. It now
  inherits only the variables a shell, git, `gh`, the CLI and its HTTP client
  need, the child's own Anthropic credential, endpoint and models (by exact
  name, so not an admin key), cloud provider profile and region names, those
  starting with `LC_`, `XDG_`, `JULIA_`, `JULIAUP_` or `CLAUDE_` (the
  nested-session variables still dropped; none of these prefixes passes a
  secret-looking name), and the variables the new `child_env_passthrough`
  config field names, by exact name. A value holding a Slack token, session
  cookie or webhook URL anywhere (recognized by its shape, alone or in a
  header) never passes, under any name; a URL carrying a user name or
  password, such as a proxy's, passes only when the channel names the
  variable. The variables SlackClaw sets per run are never inherited. The
  channel's own bot token still reaches the run as `SLACKCLAW_BOT_TOKEN`, for
  the upload helper and channel helper scripts. A channel whose runs need a
  variable outside the allow list (an API key for a tool, `GH_TOKEN`) lists it
  in `child_env_passthrough` before upgrading.
- **Not a sandbox.** The allow list covers the environment a run inherits. A
  run is the monitor's own OS user and can still read the files the monitor
  can (`slackclaw.env`, which `setup()` writes into `repo_dir` by default, a
  shell startup file that exports tokens) and the monitor's process
  environment. Keep token files out of the folders runs work in. Since every
  run through 0.7.4 held the app-level token and any other workspace's token
  in the monitor's environment, rotating those tokens after upgrading is the
  safe course.
- **A run that cannot start no longer posts its environment.** When `claude`
  could not be started (a moved `repo_dir`, `claude` missing from `PATH`), the
  failure reason posted to the thread was the spawn error's text, which spells
  out the whole command with its environment, so its tail could carry the bot
  token and the Anthropic key into Slack and the log carried all of it. The
  reason is now the error and the folder only.

### Changed

- **Runs keep Claude Code's own system prompt.** SlackClaw's instructions (the
  channel's `system_prompt`, the directive instructions and the upload
  instructions) were passed with `--system-prompt`, which replaces Claude
  Code's built-in system prompt, so runs started from Slack lacked its
  instructions on using its tools, on confirming before hard-to-reverse or
  outward-facing actions, and on citing code. They are now passed with
  `--append-system-prompt` and follow the built-in prompt. The text SlackClaw
  sends is unchanged; each run reads a few thousand more input tokens.
- **Claude Code's auto memory is off in runs** (new `auto_memory` config
  field, default `false`). The built-in prompt tells a session to read the
  repository's memory index and save memories to it; with it a channel
  member's message could become a memory that later threads, and a person's
  own Claude sessions in that repository, load and act on. Runs now get
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, so they neither read nor write that
  folder. Before, runs read the memory index but were never told to save to
  it; a channel that relies on the index sets `auto_memory = true`, which
  also lets its runs save memories.

### Upgrading

- Variables runs no longer inherit unless listed in `child_env_passthrough`:
  everything outside the allow list (see the Features page), for example a
  tool's API key (`ZOTERO_API_KEY`), `GH_TOKEN`/`GITHUB_TOKEN`, cloud secret
  keys, `npm_config_*` other than the cache location, and `SLACKCLAW_*` names
  other than those SlackClaw sets per run. Entries are exact names
  (`"ZOTERO_API_KEY"`; an entry ending in `*` is logged and ignored). A
  launcher that builds `SlackClawConfig` for a fleet needs a way to set
  `child_env_passthrough` per channel. SlackClaw logs the name of a variable it
  drops for its value.
- Status files are now `<status_file>.<channel>.<thread ts>`: a repository
  that ignores them needs `.slackclaw_status*` (or `<status_file>*`), and the
  single status file 0.7.4 and earlier used is no longer read or removed
  (delete one left behind by hand).
- Claude Code records a conversation's system prompt at its first request, so
  a thread open at the upgrade keeps the replacing prompt until its
  conversation is compacted; new threads get the built-in prompt.
- Runs no longer see the repository's Claude Code memory index (see Changed);
  set `auto_memory = true` for a channel whose runs need it.

### Fixed

- **Each run has its own status file.** All runs in a `repo_dir` watched one
  `.slackclaw_status`, so with two runs at once one run's progress was posted
  in the other's thread, and the first to finish deleted the other's file. A
  run's status file is now `<status_file>.<channel>.<thread ts>` in
  `repo_dir` (as an absolute path), given to the child as `SLACKCLAW_STATUS`;
  it is removed when the run ends and when the next run in the thread starts,
  and the monitor removes its channel's leftovers when it starts (a run it
  stopped mid-way). A prompt that tells Claude to write `.slackclaw_status` must name
  `$SLACKCLAW_STATUS` instead, when that variable is set (listen and proactive
  runs have none). `validate_fleet` no longer warns about a shared
  `status_file`.

## [0.7.4] — 2026-11-25

Patch: a failed Claude run no longer ends its Slack thread.

### Fixed

- **A failed run keeps its thread.** `run_agent_loop!` tracked a thread only
  when the run returned a session id, and `run_claude` returned none on a
  non-zero exit, so a thread whose first run failed was never tracked: the
  reconcile poll reads replies only in tracked threads, and a reply there
  started a run only if Socket Mode delivered it. Now every run (a non-zero
  exit, a step-limit stop, a timeout, an exception in the loop, a success that
  prints no id) leaves its thread tracked, so the next reply starts a new run
  whether it arrives by socket or by the reconcile poll.
- **A failed exit keeps its session id.** With `--output-format json` the CLI
  prints its result object on a failed exit too, with `session_id`. It is
  now kept, so the next reply resumes the same session with what the failed
  run already did. A timed-out run's session is the id of a result printed
  before the overrun, else the session it resumed. With no id (nothing on
  stdout, a fresh run's timeout) the thread keeps the session it had; a thread with none yet starts the next reply fresh, and
  its prompt carries `REVIVED_THREAD_NOTE`, which now says only that the
  earlier conversation is not available (it no longer names a cause, which
  did not fit every case).
- **A step-limit stop reads as one.** A run stopped at `max_turns` (result
  `subtype` `error_max_turns`) has no result text, so the reply was the bare
  exit code. It now reads "Claude stopped at the step limit before
  finishing."
- **Every failed run's reply ends with a line about replying**: "Reply in this
  thread to continue; the next run resumes this one." when the session the
  thread resumes holds the failed run's work (a run in it printed its id, or a
  resumed run timed out in it), and "Reply in this thread to try again, saying
  what is still to be done: this run left nothing to resume, though some of
  its work may have run." when it does not (a start-up failure, a fresh run
  that timed out: the thread's earlier session, if any, is still resumed). A
  timed-out run's session is the id of a result printed before the overrun,
  else the session it resumed (the CLI writes the transcript as it goes, under
  the same id). A lone stdout event of another type (`system` init) is not
  read as a result. The reason text before it is unchanged from 0.7.2, cut to
  3000 characters so the line always fits.
- **A follow-up firing in another session is told so.** When a scheduled
  follow-up resumes a session other than the one that scheduled it (the
  thread started over since: a refused resume, or a late message an older
  version ran fresh), its prompt carries `FOLLOWUP_OTHER_SESSION_NOTE`, so
  Claude asks rather than guesses what it refers to. It is decided when the
  follow-up fires, so a restart in between does not lose it.
- **A stale session id is dropped, and the message runs again.** A
  `--resume` of a session the CLI no longer has ("No conversation found with
  session ID") failed every reply in that thread. The id is now cleared and
  the same message runs again at once, once per dispatched message: fresh,
  with `REVIVED_THREAD_NOTE`, or resuming the thread's own session when it
  holds a different one. The refusal is read from the raw run (a resume was
  asked, nothing on stdout, the refusal for that id as its own stderr line,
  bare or after "Error: "), never from posted text, and only the refused id is
  cleared.
  `ClaudeResult` gains `session_missing::Bool`; the five-argument constructor
  stays and sets it false. The transient-failure retries skip a refused
  resume.
- **A thread's reply cursor is on Slack's clock.** After each run the cursor
  was reset to the host's current time, so a reply posted while the run was
  finishing (or within any host clock lead over Slack) was never read by the
  poll. A thread now starts at the message its run answered (or the parent
  post, or a follow-up's notice) and keeps the last reply read, on every path
  that tracks threads (the agent loop, listen, proactive). A run that knows no
  such Slack timestamp does not track a thread it finds untracked. A reply
  posted during a thread's first run is read by the next poll after the run.
  The tracked session is updated in place under the dispatch lock, and
  `claim_thread_reply!` claims only against the thread's tracked entry, so a
  poll holding a session across a Slack call never claims on a dead cursor.
- **One run per thread.** `run_agent_loop!` refuses a second run in a thread
  that already has one, whatever dispatched it (a reply, a late top-level
  message, a scheduled follow-up); a reply gets "Still working", as before.
  The check and the busy mark are one step with no yield in between. The
  dispatcher's own Slack call (👀, the follow-up notice) runs inside the run,
  before Claude starts, so it is never posted after the run's reply.
  `run_agent_loop!` gains a `before_run` keyword for it and returns whether
  the run started.
- **A reply to a failure notice starts a run.** The ❌ reaction goes on
  first, then the run lets go of the thread (busy mark released, status file
  cleared), then the reason is posted, so a reply sent while the notice is
  still being posted starts a run instead of "Still working". A run clears
  only its own busy mark, and once it has let go it records nothing more: a
  failed post is logged, never sent back through the loop's error path. A
  failed reaction or status-file cleanup on that path is logged and never
  stops the release or the post.
- **A late top-level message keeps its thread's conversation.** When the
  socket missed a top-level message but delivered a reply in its thread, the
  reply revives the thread and runs (as before: a webhook post, whose event
  never moves the cursor, has nothing else to read its replies). When
  reconciliation then reads the message and finds its thread running, the
  message is not run (one run per thread; 0.7.3 ran it beside the reply) and
  says so, asking for a reply with the request. When it finds its thread
  tracked and idle (the reply already ran), it resumes the thread's session
  instead of starting a new one, so the thread keeps one conversation and a
  follow-up the reply scheduled resumes the one that has its request. Its
  prompt carries `LATE_PARENT_NOTE`: it is the thread's original post,
  reaching Claude after replies already handled and possibly edited since, so
  on a conflict with those replies Claude asks which one stands. This also
  covers Slack's `me_message` status posts, which the socket skips and
  reconciliation reads.
- **Expiry spares threads with work to come.** A thread with a run in flight
  or a follow-up scheduled is not expired, and such threads sit beside
  `max_active_threads`, which counts the other threads only.
- **A scheduled follow-up resumes the thread's current session**, not the
  older id it was saved with (a thread that holds no session runs it fresh,
  with `REVIVED_THREAD_NOTE`). It waits while its thread is running or no task
  slot is free, instead of running beside it, and is saved as deferred
  (`ScheduledTask` gains `deferred::Bool`; the four-argument constructor
  stays), so a restart keeps it though its time has passed, for up to a day.
- **A failed state save no longer hides the run's reply.** It is logged, and
  the run's reason is still posted. A failed ✅ after a posted answer is only
  logged too, instead of an error reply inviting a retry of finished work, as
  is a failed save or confirmation of a follow-up that is already queued.
- The status-file watcher stops when `run_claude` throws, and no longer posts
  once more after its run has ended.

Threads already untracked in a saved state stay untracked; a new top-level
message starts a new thread. A request turned away because every task slot is
busy is not tracked, as before.

## [0.7.3] — 2026-10-15

Patch: a message with files and no text is dispatched, and its files are named
in the prompt.

### Fixed

- **File-only posts are dispatched.** `should_process` dropped any message
  whose text was blank, so a caption-less photo never ran. A message with files
  now dispatches, whatever its caption.
- **Attachments are named in the prompt.** Each file adds one line,
  `[attached file: IMG_1234.jpg (image/jpeg, id F0ABC)]`, after the caption,
  separated from it by a blank line (with no caption the lines are the whole
  text). The socket and reconcile paths build the text in the same helper
  (`message_text`), so one payload gives one text on either path. A Slack
  Connect socket event can carry only a file id, so its note can read
  `unnamed file` where the history copy names the file. Only the name, mimetype
  and id reach the prompt; the file is not downloaded. Missing fields fall back
  to the title, then to `unnamed file`. File names are user-controlled, so line
  breaks in them become spaces: a name cannot forge a `[from …]` line.
- Bot and self filtering is unchanged: the bot's own uploads and `bot_id`
  posts are still dropped, and a message with neither text nor files is still
  dropped.
- **Proactive commands read the caption only.** `proactive on`, `proactive off`
  and `proactive every …` are matched against the caption, so a file named
  `proactive off.txt` cannot toggle proactive mode.

## [0.7.2] — 2026-10-15

Patch: a failed `claude` run now names the real reason. (0.7.0–0.7.1 were
released without changelog entries; see the GitHub releases for their notes.)

### Fixed

- **Non-zero exits post the CLI's reason, not stderr noise.** With
  `--output-format json` the CLI prints its result object to stdout even when
  it fails, and that object's `result` text is the reason (a weekly limit, an
  expired login). `run_claude` built its message from stderr alone, so a
  failure posted an unrelated MCP policy warning as the cause, or only the
  bare exit code when stderr was empty. The reason now comes from the stdout
  result text (new `exit_failure_message`); a stderr tail is used only when
  stdout carries none, labelled `stderr:` because it is evidence, not a parsed
  reason. The `@error` journal line records the same reason. The retry
  condition is unchanged (a non-zero exit is retried only when stdout is
  empty), so these failures are still not retried. A `result` that is null or
  not a string gives no reason (the stderr tail is used) instead of posting the
  raw JSON. Reasons are capped at 500 characters with a `…` marker: a parsed
  result keeps its head, raw stdout and the stderr tail keep their end.

## [0.6.2] — 2026-08-16

Patch: narrated-`[SKIP]` spam fix. (0.5.1–0.6.1 were released without
changelog entries; see the GitHub releases for their notes.)

### Fixed

- **Narrated declines no longer post as channel spam.** Models reliably
  narrate a skip and leave the token at the END ("…nothing new to report.
  `[SKIP]`"); the listen/proactive suppression was a prefix check, so the
  whole narration posted. Prompt-side hardening empirically failed to stop
  it, so both paths now suppress on **containment** (`occursin`, new
  `is_decline` helper) — on these paths a false positive merely suppresses an
  optional post, while a false negative is user-visible spam. The
  primary/thread `allow_skip` gate is **unchanged** (exact match): there the
  asymmetry runs the other way — a false positive would eat a real answer in
  the user's own thread (the 0.5.0 rationale).

### Added

- A containment-suppressed proactive run still appends its **full** text to
  `.slackclaw_proactive_log`, tagged `[suppressed]`, so the next cycle's
  dedup keeps the reasoning (suppressed ≠ lost). Posted entries keep the old
  truncated one-liner format (both via the new `append_proactive_log`).

## [0.5.0] — 2026-08-11

Teammate-behavior release. Both new config fields default **off**, so existing
deployments that don't opt in behave as before (the one deliberate default
change: the start/stop banners no longer post unless enabled).

### Added

- **`allow_skip::Bool = false`** — the primary/thread path can now decline to
  answer: a Claude reply of exactly `[SKIP]` posts nothing and adds no
  reaction. Previously the literal `[SKIP]` string was posted to the channel.
  The match is **exact** (`strip(text) == "[SKIP]"`), deliberately stricter
  than the `startswith` checks on the listen/proactive paths — a false positive
  here would eat a real answer in the user's own channel. A skipped message
  still updates the thread session, so later in-thread replies keep continuity.
  Mechanism only: instruct Claude about the convention via `system_prompt`.
- **Self-mentions legible to Claude** — mentions of the bot itself are
  rewritten `<@U…>` → `@you` in dispatched prompts (all paths), so Claude can
  tell when *it* was tagged — the basis for deciding to skip. Other users' IDs
  are left raw (resolving them needs `users.info` + `users:read`; follow-up).
- **`announce_startup::Bool = false`** — the `_SlackClaw monitor started_` /
  `_… stopped_` banners are now opt-in. Under supervised restarts
  (systemd `Restart=always`) a crash-loop posted both banners every cycle.
- `SKIP_TOKEN` constant shared by all three skip sites (listen relevance,
  proactive, primary gate).

## [0.4.1] — 2026-06-29

### Changed

- Compat only: widened `HTTP` to `"1, 2"` and `JSON` to `"0.21, 1"`. No code
  changes.

## [0.4.0] — 2026-06-23

### Changed (breaking)

- **Socket Mode is now the only delivery mode.** Timer-driven polling has been
  removed. `run_monitor` always connects via Socket Mode, and `SLACK_APP_TOKEN`
  (an `xapp-` token with `connections:write`) is now **required**.
- Removed the `socket_mode` field from `SlackClawConfig` — it is implicitly
  always on. Configs that set `socket_mode = true`/`false` must drop it.
- `poll_interval_s` is now solely the background housekeeping cadence
  (scheduled/proactive checks + the reconcile tick), not a message-poll loop.
- Removed `poll_loop!`/`poll_once!` (internal). The history-fetch machinery
  (`reconcile_messages!` and the `claim_*!` cursor gates) is retained — it is
  the gap-fill reconciliation that backs at-least-once push delivery.

### Added

- **Setup assistant.** `SlackClaw.setup()` provisions a Slack app from a
  generated manifest and automates everything an API can do: token validation,
  channel resolution, auto-join of public channels, a live Socket Mode
  self-test, a gitignored `slackclaw.env`, and a confirmation post. The only
  human steps (create app from manifest, install, mint the app token) are
  grouped into one browser session — no back-and-forth. Also available
  (unexported — call as `SlackClaw.generate_manifest`, etc.):
  `generate_manifest`, `verify_setup`, `print_setup_instructions`,
  `socket_selftest`.
- Slack API helpers `slack_conversations_list`, `slack_conversations_join`,
  and `slack_auth_test_info`.
- Documenter "Features" page (agent directives, listening, proactive mode,
  progress updates, concurrency, persistence).

### Fixed

- The generated app manifest declares `files:write`, which the file-upload path
  (`slack_upload_file`) requires but the previously documented scope set
  omitted. The manifest also adds `groups:read` and `im:history` to match what
  the code and event subscriptions actually need.
- `run_claude` now captures the Claude CLI's **stderr** and classifies a
  non-zero exit as a real failure (`success = false`) instead of posting
  `"Process failed (exit code non-zero)"` to the thread as if it were Claude's
  reply. Transient non-zero exits (rate limit / overload) are retried with
  exponential backoff (new `claude_max_retries` / `claude_retry_backoff_s`
  config). A timeout now SIGTERMs the subprocess instead of only interrupting
  the read, which could orphan the `claude` process.

## [0.3.0]

- `run_socket_fleet`: serve many channels of one workspace over a single socket.

## [0.2.1]

- Age-based thread expiry (`max_thread_idle_s`, default 7 days).

## [0.2.0]

- Slack Socket Mode (push) event delivery.
