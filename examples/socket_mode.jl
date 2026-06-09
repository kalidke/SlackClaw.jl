using SlackClaw

# Socket Mode (push) — sub-second delivery instead of polling.
#
# Requires SLACK_BOT_TOKEN, SLACK_CHANNEL_ID, and SLACK_APP_TOKEN (app-level
# xapp- token with connections:write). The Slack app must have Socket Mode
# enabled and bot events message.channels/message.groups/message.im subscribed
# (see README "Enable Socket Mode").
#
# Note: one Socket Mode monitor per workspace token — Slack load-balances
# events across open sockets, so multiple sockets under the same app would
# each see only a subset of events.

run_monitor(SlackClawConfig(
    socket_mode = true,
    repo_dir = "/home/kalidke/julia_shared_dev/SMLMAnalysis",
    model = "sonnet",
    max_budget_usd = 1.0,
    reconcile_interval_s = 300,  # gap-fill poll cadence
))
