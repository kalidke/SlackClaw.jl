using SlackClaw

# Serve MANY channels of one workspace over a SINGLE socket — the right shape
# for a whole workspace on push. Each channel gets its own repo_dir and state.
#
# All configs share one bot token and one app token (one Slack app == one
# socket; Slack load-balances events across an app's open sockets, so a
# workspace must be served by exactly one connection). Channels that share a
# repo_dir must each set a distinct state_file.

bot = ENV["SLACK_BOT_TOKEN"]
app = ENV["SLACK_APP_TOKEN"]

run_socket_fleet([
    SlackClawConfig(slack_bot_token=bot, app_token=app,
                    slack_channel_id="C0AAAAAAA", repo_dir="/path/to/repo-a", model="sonnet"),
    SlackClawConfig(slack_bot_token=bot, app_token=app,
                    slack_channel_id="C0BBBBBBB", repo_dir="/path/to/repo-b", model="sonnet"),
])
