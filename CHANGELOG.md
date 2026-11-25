# Changelog

Notable changes to SlackClaw.jl. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses
[Semantic Versioning](https://semver.org/) (pre-1.0, so minor bumps may break).

## [Unreleased] (0.7.4-DEV)

Patch: a failed Claude run no longer ends its Slack thread.

### Fixed

- **A failed run keeps its thread.** `run_agent_loop!` tracked a thread only
  when the run returned a session id, and `run_claude` returned none on a
  non-zero exit, so a thread whose first run failed was never tracked: the
  reconcile poll reads replies only in tracked threads, and a reply there
  started a run only if Socket Mode delivered it. Now a top-level message's
  thread is tracked at dispatch, and any run (a non-zero exit, a step-limit
  stop, a timeout, an exception in the loop, a success that prints no id)
  leaves its thread tracked, so the next reply starts a new run whether it
  arrives by socket or by the reconcile poll. A request turned away as busy
  is tracked too, and its message now reads "Busy with N task(s) — reply in
  this thread to try again."
- **A failed exit keeps its session id.** With `--output-format json` the CLI
  prints its result object on a failed exit too, with `session_id`. It is
  now kept, so the next reply resumes the same session with what the failed
  run already did. With no id (a timeout, nothing on stdout) the thread keeps
  the session it had; a thread with none yet starts the next reply fresh, and
  its prompt carries `REVIVED_THREAD_NOTE`, now worded for both an expired
  thread and a failed run.
- **A step-limit stop reads as one.** A run stopped at `max_turns` (result
  `subtype` `error_max_turns`) has no result text, so the reply was the bare
  exit code. It now reads "Claude stopped at the step limit before
  finishing."
- **Every failed run's reply ends with a line about replying**: "Reply in
  this thread to continue; the next run resumes this one." when there is a
  session to resume, and "Reply in this thread to try again; this run kept
  no context, so include the request." when there is not. The reason text
  before it is unchanged from 0.7.2.
- **A stale session id is dropped, and the message runs again.** A
  `--resume` of a session the CLI no longer has ("No conversation found with
  session ID") failed every reply in that thread. The id is now cleared and
  the same message runs again at once: fresh, with `REVIVED_THREAD_NOTE`, or
  resuming the thread's own session when it holds a newer one (a scheduled
  task fires with the id it was saved with). Once per dispatched message. The refusal is
  read from the raw run (a resume was asked, nothing on stdout, the phrase
  naming that id on stderr), never from posted text, and only the refused id
  is cleared.
  `ClaudeResult` gains `session_missing::Bool`; the five-argument constructor
  stays and sets it false. The transient-failure retries skip a refused
  resume.
- **A thread's reply cursor follows Slack's clock only.** After each run the
  cursor was reset to the host's current time, so a reply posted while the
  run was finishing (or within any host clock lead over Slack) was never read
  by the poll. A thread's cursor now starts at its parent's timestamp and
  stays at the last reply read, on every path that tracks threads (the agent
  loop, listen, proactive). The tracked session is updated in place, so a
  poll that holds it across a Slack call claims against the live cursor, and
  a poll whose thread was re-tracked during the call drops its stale read.
- **A reply to a failure notice starts a run.** The ❌ reaction goes on
  first, then the thread is freed, then the reason is posted, so a reply sent
  while the notice is still being posted starts a run instead of "Still
  working". A run clears only its own busy mark. A failed reaction on a
  failure path is logged and never stops the post.
- **A thread is busy from dispatch.** Every dispatcher (top-level message,
  thread reply, scheduled follow-up) starts the run, which marks the thread
  busy, before its own Slack calls (👀, the follow-up notice), so a reply
  read during those calls cannot start a second run ahead of the first.
- **A claim on a stale session fails.** `claim_thread_reply!` claims only
  against the thread's tracked entry, so a poll whose thread expired or was
  re-tracked while it dispatched an earlier reply drops the rest of its batch.
- **Expiry spares threads with work to come.** A thread with a run in flight
  or a follow-up scheduled is not expired: re-tracking it afterwards would
  read its replies again from an earlier point. A thread the agent loop must
  track again starts after the message it answered (a scheduled run: at the
  current time), never at its parent.
- **A scheduled follow-up resumes the thread's current session**, not the
  older id it was saved with.
- **A failed state save no longer hides the run's reply.** It is logged, and
  the run's reason is still posted.
- The status-file watcher stops even when `run_claude` throws.

Threads already untracked in a saved state stay untracked; a new top-level
message starts a new thread.

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
