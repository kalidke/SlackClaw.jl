"""
Configuration for SlackClaw monitor.

All fields have sensible defaults. `slack_bot_token` and `slack_channel_id`
default to reading from environment variables.
"""
Base.@kwdef mutable struct SlackClawConfig
    slack_bot_token::String = ENV["SLACK_BOT_TOKEN"]
    slack_channel_id::String = ENV["SLACK_CHANNEL_ID"]
    app_token::String = get(ENV, "SLACK_APP_TOKEN", "")  # app-level xapp- token (Socket Mode)
    socket_mode::Bool = false           # true = Socket Mode (push), false = polling; no silent fallback
    reconcile_interval_s::Int = 300     # Socket Mode: gap-fill poll cadence
    poll_interval_s::Int = 10
    repo_dir::String = pwd()
    max_budget_usd::Float64 = 0.0  # 0 = no limit flag passed
    model::String = ""              # empty = use CLI default
    claude_timeout_s::Int = 3600
    max_turns::Int = 30
    allowed_tools::Vector{String} = String[]
    max_concurrent_tasks::Int = 5
    max_active_threads::Int = 3
    max_thread_idle_s::Int = 604800     # drop tracked threads idle this long (7d; 0 = never)
    max_continue::Int = 10              # max consecutive [CONTINUE] before forced stop
    system_prompt::String = """Your responses are posted to a Slack channel as threaded replies. Keep under 2000 chars. Be concise and direct. Do NOT use markdown — Slack does not render it. Use Slack-native formatting: *bold*, _italic_, `code`, ```code blocks```. No headers (#), no dash-bullet lists. URLs work fine as plain text. If a task will take more than a few seconds, first reply with a brief message explaining what you are about to do and what the user should expect."""
    agent_directives::Bool = true       # enable [CONTINUE]/[SCHEDULE] directives
    status_file::String = ".slackclaw_status"
    status_poll_s::Int = 30             # how often to check status file during execution
    bot_user_id::String = ""
    listen_channel_ids::Vector{String} = String[]  # channels to poll (listen-only, respond in primary)
    proactive_enabled::Bool = false                 # enable periodic proactive checks
    proactive_prompt::String = ""                   # prompt with suggestions for proactive actions
    proactive_interval_s::Int = 3600                # seconds between proactive checks (default 1h)
end
