const SLACK_API_BASE = "https://slack.com/api"

"""
    slack_request(method, endpoint, config; query=nothing, body=nothing) -> Dict

Make authenticated Slack API request. Handles JSON parsing and rate-limit (429) retries.
"""
function slack_request(method::Symbol, endpoint::String, config::SlackClawConfig;
                       query::Union{Dict,Nothing}=nothing,
                       body::Union{Dict,Nothing}=nothing)
    url = "$SLACK_API_BASE/$endpoint"
    headers = [
        "Authorization" => "Bearer $(config.slack_bot_token)",
        "Content-Type" => "application/json; charset=utf-8",
    ]

    max_retries = 3
    for attempt in 1:max_retries
        resp = if method == :get
            q = query === nothing ? Dict() : query
            query_str = join(["$k=$(HTTP.URIs.escapeuri(string(v)))" for (k, v) in q], "&")
            full_url = isempty(query_str) ? url : "$url?$query_str"
            HTTP.get(full_url; headers, status_exception=false)
        else
            HTTP.post(url; headers, body=JSON.json(body === nothing ? Dict() : body),
                      status_exception=false)
        end

        if resp.status == 429
            retry_after = parse(Int, HTTP.header(resp, "Retry-After", "5"))
            if attempt < max_retries
                @warn "Slack rate limited, retrying in $(retry_after)s" endpoint attempt
                sleep(retry_after)
                continue
            end
        end

        data = JSON.parse(String(resp.body))
        if !get(data, "ok", false)
            error("Slack API error on $endpoint: $(get(data, "error", "unknown"))")
        end
        return data
    end
    error("Slack API: max retries exceeded for $endpoint")
end

"""
    slack_auth_test(config) -> String

Call `auth.test` and return the bot's own user ID.
"""
function slack_auth_test(config::SlackClawConfig)
    data = slack_request(:post, "auth.test", config)
    return data["user_id"]
end

"""
    slack_get_history(config, oldest) -> (Vector{Dict}, Vector{Dict})

Fetch channel messages newer than `oldest` timestamp.
Returns `(parsed_messages, raw_dicts)` in chronological order (oldest first).
"""
function slack_get_history(config::SlackClawConfig, oldest::String)
    data = slack_request(:get, "conversations.history", config;
        query=Dict(
            "channel" => config.slack_channel_id,
            "oldest" => oldest,
            "limit" => "100",
        ))
    raw_msgs = get(data, "messages", [])
    reverse!(raw_msgs)  # API returns newest-first; we want oldest-first
    return raw_msgs
end

"""
    slack_post_message(config, text; thread_ts="") -> String

Post a message to the configured channel. Returns the message `ts`.
If `thread_ts` is non-empty, posts as a thread reply.
"""
function slack_post_message(config::SlackClawConfig, text::String; thread_ts::String="")
    body = Dict(
        "channel" => config.slack_channel_id,
        "text" => text,
    )
    if !isempty(thread_ts)
        body["thread_ts"] = thread_ts
    end
    data = slack_request(:post, "chat.postMessage", config; body)
    return data["ts"]
end

"""
    slack_get_replies(config, thread_ts, oldest) -> Vector{Dict}

Fetch replies in a thread newer than `oldest`. Returns in chronological order.
The first message (the thread parent) is always included by the API; we skip it.
"""
function slack_get_replies(config::SlackClawConfig, thread_ts::String, oldest::String)
    data = slack_request(:get, "conversations.replies", config;
        query=Dict(
            "channel" => config.slack_channel_id,
            "ts" => thread_ts,
            "oldest" => oldest,
            "limit" => "100",
        ))
    raw_msgs = get(data, "messages", [])
    # Filter out the parent message and anything not newer than oldest
    filter!(m -> get(m, "ts", "") != thread_ts && get(m, "ts", "") > oldest, raw_msgs)
    return raw_msgs
end

"""
    slack_add_reaction(config, ts, emoji)

Add an emoji reaction to a message. Silently ignores "already_reacted" errors.
"""
function slack_add_reaction(config::SlackClawConfig, ts::String, emoji::String)
    body = Dict(
        "channel" => config.slack_channel_id,
        "timestamp" => ts,
        "name" => emoji,
    )
    try
        slack_request(:post, "reactions.add", config; body)
    catch e
        # "already_reacted" is fine, re-throw anything else
        msg = string(e)
        contains(msg, "already_reacted") || rethrow()
    end
end
