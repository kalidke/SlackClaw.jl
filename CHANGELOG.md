# Changelog

Notable changes to SlackClaw.jl. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses
[Semantic Versioning](https://semver.org/) (pre-1.0, so minor bumps may break).

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
