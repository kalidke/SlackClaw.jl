"""
Slack message representation and filtering.
"""
struct SlackMessage
    ts::String
    user::String
    text::String
    thread_ts::String
end

"""
    parse_slack_messages(messages::Vector) -> Vector{SlackMessage}

Parse raw Slack API message dicts into `SlackMessage` structs.
"""
function parse_slack_messages(messages::Vector)
    result = SlackMessage[]
    for msg in messages
        haskey(msg, "ts") || continue
        push!(result, SlackMessage(
            get(msg, "ts", ""),
            get(msg, "user", ""),
            get(msg, "text", ""),
            get(msg, "thread_ts", ""),
        ))
    end
    return result
end

"""
    should_process(msg::SlackMessage, config::SlackClawConfig, raw::Dict) -> Bool

Return `true` if this message should be dispatched to Claude.
Skips bot messages, messages from our own bot user, and empty text.
"""
function should_process(msg::SlackMessage, config::SlackClawConfig, raw::Dict)
    haskey(raw, "bot_id") && return false
    get(raw, "subtype", "") == "bot_message" && return false
    msg.user == config.bot_user_id && return false
    isempty(strip(msg.text)) && return false
    return true
end
