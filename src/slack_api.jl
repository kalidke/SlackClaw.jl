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
    slack_conversations_info(config, channel_id) -> Dict

Fetch channel metadata. Returns the full channel info dict.
"""
function slack_conversations_info(config::SlackClawConfig, channel_id::AbstractString)
    data = slack_request(:get, "conversations.info", config;
        query=Dict("channel" => channel_id))
    return data["channel"]
end

"""
    slack_get_history(config, oldest; channel_id=config.slack_channel_id) -> Vector{Dict}

Fetch channel messages newer than `oldest` timestamp.
Returns raw message dicts in chronological order (oldest first).
"""
function slack_get_history(config::SlackClawConfig, oldest::AbstractString;
                           channel_id::AbstractString=config.slack_channel_id)
    data = slack_request(:get, "conversations.history", config;
        query=Dict(
            "channel" => channel_id,
            "oldest" => oldest,
            "limit" => "100",
        ))
    raw_msgs = get(data, "messages", [])
    reverse!(raw_msgs)  # API returns newest-first; we want oldest-first
    return raw_msgs
end

"""
    slack_post_message(config, text; thread_ts="", channel_id=config.slack_channel_id) -> String

Post a message to a channel. Returns the message `ts`.
If `thread_ts` is non-empty, posts as a thread reply.
"""
function slack_post_message(config::SlackClawConfig, text::AbstractString;
                            thread_ts::AbstractString="",
                            channel_id::AbstractString=config.slack_channel_id)
    body = Dict(
        "channel" => channel_id,
        "text" => text,
    )
    if !isempty(thread_ts)
        body["thread_ts"] = thread_ts
    end
    data = slack_request(:post, "chat.postMessage", config; body)
    return data["ts"]
end

"""
    slack_get_replies(config, thread_ts, oldest; channel_id=config.slack_channel_id) -> Vector{Dict}

Fetch replies in a thread newer than `oldest`. Returns in chronological order.
The first message (the thread parent) is always included by the API; we skip it.
"""
function slack_get_replies(config::SlackClawConfig, thread_ts::AbstractString, oldest::AbstractString;
                           channel_id::AbstractString=config.slack_channel_id)
    data = slack_request(:get, "conversations.replies", config;
        query=Dict(
            "channel" => channel_id,
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
    slack_upload_file(config, file_path; thread_ts="", channel_id=config.slack_channel_id,
                      title="", initial_comment="") -> Dict

Upload a file to Slack using the V2 three-step flow:
1. `files.getUploadURLExternal` — get pre-signed upload URL
2. POST file bytes to the upload URL
3. `files.completeUploadExternal` — finalize and share to channel/thread
"""
function slack_upload_file(config::SlackClawConfig, file_path::AbstractString;
                           thread_ts::AbstractString="",
                           channel_id::AbstractString=config.slack_channel_id,
                           title::AbstractString="",
                           initial_comment::AbstractString="")
    isfile(file_path) || error("slack_upload_file: file not found: $file_path")
    filename = basename(file_path)
    filesize = stat(file_path).size
    disp_title = isempty(title) ? filename : title

    # Step 1: Get upload URL
    data = slack_request(:get, "files.getUploadURLExternal", config;
        query=Dict("filename" => filename, "length" => string(filesize)))
    upload_url = data["upload_url"]
    file_id = data["file_id"]

    # Step 2: Upload file bytes (multipart POST to pre-signed URL, not Slack API)
    file_bytes = read(file_path)
    form = HTTP.Form(Dict("file" => HTTP.Multipart(filename, IOBuffer(file_bytes))))
    resp = HTTP.post(upload_url; body=form, status_exception=false)
    resp.status in 200:299 || error("slack_upload_file: upload returned HTTP $(resp.status)")

    # Step 3: Complete upload and share
    complete_body = Dict{String,Any}(
        "files" => [Dict("id" => file_id, "title" => disp_title)],
        "channel_id" => channel_id,
    )
    !isempty(thread_ts) && (complete_body["thread_ts"] = thread_ts)
    !isempty(initial_comment) && (complete_body["initial_comment"] = initial_comment)

    return slack_request(:post, "files.completeUploadExternal", config; body=complete_body)
end

"""
    slack_add_reaction(config, ts, emoji; channel_id=config.slack_channel_id)

Add an emoji reaction to a message. Silently ignores "already_reacted" errors.
"""
function slack_add_reaction(config::SlackClawConfig, ts::AbstractString, emoji::AbstractString;
                            channel_id::AbstractString=config.slack_channel_id)
    body = Dict(
        "channel" => channel_id,
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
