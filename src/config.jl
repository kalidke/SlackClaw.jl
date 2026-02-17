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
    max_continue::Int = 10              # max consecutive [CONTINUE] before forced stop
    system_prompt::String = """Keep responses under 2000 characters. Be concise and direct. This is a Slack channel.
If a task will take more than a few seconds, first reply with a brief message explaining what you're about to do, what steps are involved, and what the user should expect to see (e.g. status updates, follow-ups, or a final summary). Then proceed with the work."""
    agent_directives::Bool = true       # enable [CONTINUE]/[SCHEDULE] directives
    status_file::String = ".slackclaw_status"
    status_poll_s::Int = 30             # how often to check status file during execution
    bot_user_id::String = ""
end
