"""
Configuration for SlackClaw monitor.

All fields have sensible defaults. `slack_bot_token` and `slack_channel_id`
default to reading from environment variables.
"""
Base.@kwdef mutable struct SlackClawConfig
    slack_bot_token::String = ENV["SLACK_BOT_TOKEN"]
    slack_channel_id::String = ENV["SLACK_CHANNEL_ID"]
    poll_interval_s::Int = 10
    repo_dir::String = pwd()
    max_budget_usd::Float64 = 0.0  # 0 = no limit flag passed
    model::String = ""              # empty = use CLI default
    claude_timeout_s::Int = 3600
    max_turns::Int = 30
    allowed_tools::Vector{String} = String[]
    max_concurrent_tasks::Int = 5
    max_active_threads::Int = 10
    system_prompt::String = "Keep responses under 2000 characters. Be concise and direct. This is a Slack channel."
    bot_user_id::String = ""
end
