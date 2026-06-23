using SlackClaw

# First-time setup (interactive) — provisions the Slack app, scopes, Socket Mode,
# and both tokens for you, then writes them to slackclaw.env:
#
#   julia --project -e 'using SlackClaw; SlackClaw.setup()'
#
# After that, `source slackclaw.env` to load SLACK_BOT_TOKEN, SLACK_APP_TOKEN,
# and SLACK_CHANNEL_ID, then run a single-channel monitor:

run_monitor(SlackClawConfig(
    repo_dir = "/path/to/your/repo",
    model = "sonnet",
    max_budget_usd = 1.0,
))
