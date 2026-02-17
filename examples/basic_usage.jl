using SlackClaw

# Requires SLACK_BOT_TOKEN and SLACK_CHANNEL_ID environment variables.
# The bot token needs: channels:history, channels:read, chat:write, reactions:write scopes.

monitor = start_monitor(SlackClawConfig(
    repo_dir = "/home/kalidke/julia_shared_dev/SMLMAnalysis",
    model = "sonnet",
    max_budget_usd = 1.0,
    poll_interval_s = 60,
))

# Monitor runs in background via Timer. Stop with:
# stop_monitor!(monitor)
