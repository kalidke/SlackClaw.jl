using Base64: base64encode, base64decode

const CHAT_HTTP_V2 = pkgversion(HTTP).major >= 2

"""One chat transport response; streamed responses carry an empty body."""
struct ChatHTTPResponse
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
end

"""Private signal: HTTP 2.x should close a response with no selected sink."""
struct ChatHTTPDiscard <: Exception end

"""HTTP 2.x response sink, selected by its response-head trace before any write."""
mutable struct ChatHTTPStreamSink <: IO
    sink::Union{IO,Nothing}
end

function Base.unsafe_write(stream::ChatHTTPStreamSink, data::Ptr{UInt8}, count::UInt)
    return unsafe_write(stream.sink::IO, data, count)
end

Base.write(stream::ChatHTTPStreamSink, byte::UInt8) = write(stream, Ref(byte))

"""
    http_transport(method, url, headers; body=nothing, response_stream=nothing, timeout_s=20)

Make one HTTP request, without redirects, status exceptions or retries. A supplied
callback receives the status and headers and selects an IO sink, or nothing to
discard at most 64 KiB. An IO can also be supplied directly as the response sink.
HTTP.jl 1.x rounds fractional timeouts up to seconds; 2.x accepts them directly.
"""
function http_transport(method::String, url::String, headers::Vector{Pair{String,String}};
                        body=nothing, response_stream=nothing, timeout_s::Real=20)
    # With retries off, reusing a connection the server closed makes a post's outcome uncertain.
    request_headers = headers
    options = (redirect=false, status_exception=false, retry=false)
    if CHAT_HTTP_V2
        if !any(header -> lowercase(first(header)) == "connection", headers)
            request_headers = [headers; "Connection" => "close"]
        end
        options = (; options..., connect_timeout=min(10, timeout_s),
                   read_idle_timeout=timeout_s, protocol=:h1)
    else
        seconds = ceil(Int, timeout_s)
        options = (; options..., readtimeout=seconds, connect_timeout=min(10, seconds),
                   closeimmediately=true, logerrors=false)
    end
    if CHAT_HTTP_V2
        # Both open's writes and request's IOStream normalization buffer the
        # whole request in 2.x. CallbackBody keeps uploads incremental. Its
        # length defaults to unknown, so set the prepared request's public
        # content_length at RequestEvent, before HTTP/1 framing is chosen.
        request_body = body
        content_length = nothing
        if body isa IOStream
            length_header = findfirst(h -> lowercase(first(h)) == "content-length", request_headers)
            content_length = length_header === nothing ? stat(body).size - position(body) :
                parse(Int64, last(request_headers[length_header]))
            request_body = HTTP.CallbackBody(dst -> readbytes!(body, dst, length(dst)), () -> nothing)
        end
        streamed = nothing
        sink = response_stream isa Function ? ChatHTTPStreamSink(nothing) : response_stream
        trace = function(event)
            if event isa HTTP.RequestEvent && content_length !== nothing
                event.request.content_length = content_length
            elseif event isa HTTP.ResponseHeadEvent && response_stream isa Function
                response = event.response
                response_headers = Pair{String,String}[String(k) => String(v) for (k, v) in response.headers]
                streamed = ChatHTTPResponse(Int(response.status), response_headers, UInt8[])
                sink.sink = response_stream(streamed.status, response_headers)
                # A trace error closes the incoming body without reading it.
                # Discard zero bytes, within the 64 KiB allowance, rather than
                # depend on the size of HTTP's subsequent body-copy chunks.
                sink.sink === nothing && throw(ChatHTTPDiscard())
            end
        end
        response = try
            # The 1.x open path copies raw entity bytes. Keep that behavior
            # for file callbacks, including Content-Encoding: gzip responses.
            HTTP.request(method, url, request_headers, request_body;
                         response_stream=sink, trace,
                         decompress=response_stream isa Function ? false : nothing, options...)
        catch e
            # HTTP 2.x closes the incoming body on trace/sink errors. Only our
            # intentional bounded discard is a successful, empty response.
            e isa ChatHTTPDiscard || rethrow()
            return streamed
        end
    elseif response_stream isa Function
        streamed = nothing
        discarded = false
        try
            HTTP.open(method, url, request_headers; options...) do http
                try
                    body === nothing || write(http, body)
                    HTTP.closewrite(http)
                    response = HTTP.startread(http)
                    response_headers = Pair{String,String}[String(k) => String(v) for (k, v) in response.headers]
                    streamed = ChatHTTPResponse(Int(response.status), response_headers, UInt8[])
                    sink = response_stream(streamed.status, response_headers)
                    if sink === nothing
                        remaining = 65536
                        while remaining > 0 && !eof(http)
                            chunk = read(http, min(8192, remaining))
                            isempty(chunk) && break
                            remaining -= length(chunk)
                        end
                        if remaining == 0
                            # HTTP.open's cleanup would otherwise drain the rest without a bound.
                            discarded = true
                            close(http.stream)
                        end
                    else
                        while !eof(http)
                            chunk = read(http, 65536)
                            isempty(chunk) && break
                            write(sink, chunk)
                        end
                    end
                catch
                    # Also stop cleanup from draining a rejected or oversized response.
                    close(http.stream)
                    rethrow()
                end
            end
        catch
            discarded || rethrow()
        end
        return streamed
    else
        response = HTTP.request(method, url, request_headers, body === nothing ? UInt8[] : body;
                                response_stream, options...)
    end
    bytes = response_stream === nothing ? Vector{UInt8}(response.body) : UInt8[]
    return ChatHTTPResponse(Int(response.status),
        Pair{String,String}[String(k) => String(v) for (k, v) in response.headers], bytes)
end

"""Keep at most `max_bytes` UTF-8 bytes, ending at a character boundary."""
function chat_bounded_text(value::AbstractString, max_bytes::Integer)
    ncodeunits(value) <= max_bytes && return String(value)
    last_index = 0
    for i in eachindex(value)
        nextind(value, i) - 1 > max_bytes && break
        last_index = i
    end
    return last_index == 0 ? "" : String(value[firstindex(value):last_index])
end

"""Flatten a display field and bound its UTF-8 representation."""
chat_clean_field(value, max_bytes::Integer) = chat_bounded_text(clean_field(value), max_bytes)

"""Bounded, safe error with definite refusal or uncertain mutation outcome."""
struct ChatError <: Exception
    code::Symbol
    detail::String
    retry_after_s::Union{Int,Nothing}
    outcome::Symbol

    """Sanitize details before storing them, including recognizable Slack tokens."""
    function ChatError(code::Symbol, detail::AbstractString,
                       retry_after_s::Union{Int,Nothing}=nothing, outcome::Symbol=:none)
        safe = replace(detail, r"(?:xox[baprs]-|xapp-)[A-Za-z0-9-]+" => "[redacted]")
        return new(code, chat_clean_field(safe, 256), retry_after_s, outcome)
    end
end

"""Display only the sanitized error fields."""
function Base.show(io::IO, e::ChatError)
    print(io, "ChatError(", e.code, ", ", repr(e.detail), ", ",
          e.retry_after_s, ", ", e.outcome, ")")
end

"""Render a safe exception message without any underlying HTTP request."""
Base.showerror(io::IO, e::ChatError) = print(io, e.code, ": ", e.detail)

"""Build the shared error reply, omitting optional fields when absent."""
function chat_error_payload(e::ChatError)
    payload = Dict{String,Any}("error" => e.detail, "code" => String(e.code))
    e.retry_after_s === nothing || (payload["retry_after_s"] = e.retry_after_s)
    e.outcome == :none || (payload["outcome"] = String(e.outcome))
    return payload
end

"""Choose a read's absent outcome or a mutation's refused/unknown outcome."""
chat_outcome(mutation::Bool, uncertain::Bool=false) = mutation ? (uncertain ? :unknown : :refused) : :none

"""Map exceptions by type only: HTTP exception text can contain credentials."""
function chat_exception(e; mutation::Bool=false)
    while isdefined(HTTP, :RequestError) && e isa HTTP.RequestError
        e = e.error
    end
    if e isa ChatError
        return mutation && e.outcome == :none ?
            ChatError(e.code, e.detail, e.retry_after_s, :refused) : e
    end
    unavailable = e isa HTTP.ConnectError ||
                  (isdefined(HTTP, :DNSError) && e isa HTTP.DNSError)
    code = unavailable ? :unavailable : e isa HTTP.TimeoutError ? :timeout : :io_error
    uncertain = !unavailable
    return ChatError(code, "Transport: $(nameof(typeof(e)))", nothing,
                     chat_outcome(mutation, uncertain))
end

"""Whether a value is a bounded ASCII Slack identity."""
chat_valid_id(value) = value isa AbstractString && ncodeunits(value) <= 64 &&
    occursin(r"\A[A-Z0-9]{1,64}\z", value)

"""Whether a value is a bounded decimal timestamp (never a floating point value)."""
chat_valid_ts(value) = value isa AbstractString && ncodeunits(value) <= 32 &&
    occursin(r"\A[0-9]{1,20}\.[0-9]{1,10}\z", value)

"""Validate an identity or timestamp without echoing untrusted field contents."""
function chat_validate(value, field::AbstractString; timestamp::Bool=false)
    valid = timestamp ? chat_valid_ts(value) : chat_valid_id(value)
    valid || throw(ChatError(:bad_request, "Invalid $field"))
    return String(value)
end

"""Workspace credentials, attribution identity, injected transport and name cache."""
mutable struct ChatWorkspace
    id::String
    bot_token::String
    app_token::String
    channels::Vector{String}
    posting_form::Symbol
    transport::Function
    bot_user_id::String
    bot_id::String
    names::Dict{String,String}
    lock::ReentrantLock
end

"""Construct a validated chat workspace; credentials are never read from config."""
function ChatWorkspace(; id, bot_token, app_token="", channels=String[],
                         posting_form=:prefix, transport=http_transport)
    posting_form in (:custom, :prefix) || throw(ArgumentError("Invalid posting_form"))
    bot_token isa AbstractString || throw(ArgumentError("bot_token must be a string"))
    app_token isa AbstractString || throw(ArgumentError("app_token must be a string"))
    channels isa AbstractVector || throw(ChatError(:bad_request, "Invalid channels"))
    return ChatWorkspace(chat_validate(id, "workspace"), String(bot_token), String(app_token),
        [chat_validate(c, "channel") for c in channels], posting_form, transport,
        "", "", Dict{String,String}(), ReentrantLock())
end

"""Redact credentials and avoid showing the transport closure or cached contents."""
function Base.show(io::IO, ws::ChatWorkspace)
    print(io, "ChatWorkspace(id=", repr(ws.id),
          ", bot_token=[redacted], app_token=[redacted], posting_form=", ws.posting_form, ")")
end

"""Read Retry-After case-insensitively, falling back to thirty seconds."""
function chat_retry_after(headers::AbstractVector)
    for (key, value) in headers
        lowercase(key) == "retry-after" || continue
        seconds = tryparse(Int, strip(value))
        return seconds === nothing || seconds < 0 ? 30 : seconds
    end
    return 30
end

"""Map Slack's error string to the shared code and uncertainty flag."""
function chat_slack_error(error::AbstractString)
    error in ("invalid_auth", "not_authed", "account_inactive", "token_revoked", "token_expired") &&
        return (:unauthorized, false)
    error in ("missing_scope", "not_in_channel", "restricted_action", "is_archived", "channel_is_archived") &&
        return (:forbidden, false)
    error in ("channel_not_found", "thread_not_found", "message_not_found", "file_not_found", "user_not_found") &&
        return (:not_found, false)
    error == "ratelimited" && return (:rate_limited, false)
    error in ("msg_too_long", "too_large") && return (:too_large, false)
    error in ("internal_error", "fatal_error", "request_timeout", "service_unavailable") &&
        return (:unavailable, true)
    return (:bad_request, false)
end

"""Allow only bounded Slack error codes in details, redacting workspace secrets."""
function chat_safe_detail(ws::ChatWorkspace, error::AbstractString)
    ncodeunits(error) <= 64 && occursin(r"\A[a-z0-9_.]{1,64}\z", error) ||
        return "unexpected Slack error"
    safe = "Slack: $error"
    for token in (ws.bot_token, ws.app_token)
        isempty(token) || (safe = replace(safe, token => "[redacted]"))
    end
    return safe
end

"""
    chat_api(ws, method, endpoint; query=nothing, body=nothing, mutation=false, timeout_s=20)

Make exactly one authenticated Slack call through the workspace transport. Return
the parsed object or throw a typed, sanitized error; uncertain mutations are never
resubmitted. Reads omit mutation outcomes.
"""
function chat_api(ws::ChatWorkspace, method, endpoint::AbstractString;
                  query=nothing, body=nothing, mutation::Bool=false, timeout_s::Real=20)
    verb = uppercase(string(method))
    url = "$SLACK_API_BASE/$endpoint"
    headers = Pair{String,String}["Authorization" => "Bearer $(ws.bot_token)"]
    request_body = nothing
    try
        if verb == "GET"
            if query !== nothing
                encoded = join([HTTP.URIs.escapeuri(string(k)) * "=" *
                    HTTP.URIs.escapeuri(string(v)) for (k, v) in query], "&")
                isempty(encoded) || (url *= "?" * encoded)
            end
        elseif verb == "POST"
            push!(headers, "Content-Type" => "application/json; charset=utf-8")
            request_body = JSON.json(body === nothing ? Dict{String,Any}() : body)
        else
            throw(ChatError(:bad_request, "Unsupported HTTP method"))
        end
    catch e
        throw(chat_exception(e; mutation))
    end
    response = try
        ws.transport(verb, url, headers; body=request_body, timeout_s)
    catch e
        throw(chat_exception(e; mutation))
    end
    if response.status == 429
        throw(ChatError(:rate_limited, "Slack rate limited", chat_retry_after(response.headers),
                        chat_outcome(mutation)))
    elseif response.status >= 500
        throw(ChatError(:unavailable, "Slack HTTP $(response.status)", nothing, chat_outcome(mutation, true)))
    elseif !(200 <= response.status < 300)
        throw(ChatError(:bad_request, "Slack HTTP $(response.status)", nothing, chat_outcome(mutation)))
    end
    data = try
        JSON.parse(String(copy(response.body)))
    catch
        throw(ChatError(:io_error, "Invalid Slack JSON response", nothing, chat_outcome(mutation, true)))
    end
    data isa AbstractDict || throw(ChatError(:io_error, "Invalid Slack response object", nothing,
                                             chat_outcome(mutation, true)))
    ok = get(data, "ok", nothing)
    if ok !== true
        if mutation && ok !== false
            throw(ChatError(:io_error, "Slack did not confirm the mutation", nothing, :unknown))
        end
        error = get(data, "error", "unknown")
        error isa AbstractString || (error = "unknown")
        code, uncertain = chat_slack_error(error)
        retry_after = code == :rate_limited ? chat_retry_after(response.headers) : nothing
        throw(ChatError(code, chat_safe_detail(ws, error), retry_after,
                        chat_outcome(mutation, uncertain)))
    end
    return data
end

"""Authenticate the bot and reject tokens belonging to another Slack workspace."""
function chat_authenticate!(ws::ChatWorkspace)
    data = chat_api(ws, "POST", "auth.test")
    get(data, "team_id", nothing) == ws.id ||
        throw(ChatError(:unauthorized, "Slack workspace does not match"))
    user_id = chat_validate(get(data, "user_id", nothing), "bot user")
    bot_id = get(data, "bot_id", "")
    bot_id == "" || (bot_id = chat_validate(bot_id, "bot"))
    lock(ws.lock) do
        ws.bot_user_id = user_id
        ws.bot_id = bot_id
    end
    return ws
end

"""Resolve a member without locking during API work; typed failures stay uncached."""
function resolve_name!(ws::ChatWorkspace, user_id::AbstractString)
    isempty(user_id) && return "unknown"
    id = chat_validate(user_id, "user")
    cached = lock(ws.lock) do
        get(ws.names, id, nothing)
    end
    cached === nothing || return cached
    data = try
        chat_api(ws, "GET", "users.info"; query=Dict{String,Any}("user" => id))
    catch e
        e isa ChatError || rethrow()
        return id
    end
    user = get(data, "user", nothing)
    user isa AbstractDict || return id
    profile = get(user, "profile", nothing)
    profile isa AbstractDict || (profile = Dict{String,Any}())
    for value in (get(profile, "display_name", ""), get(profile, "real_name", ""), get(user, "name", ""))
        name = chat_clean_field(value, 160)
        isempty(name) && continue
        lock(ws.lock) do
            ws.names[id] = name
        end
        return name
    end
    return id
end

"""Read a string field from untrusted JSON, treating other values as absent."""
function chat_string(raw::AbstractDict, key::AbstractString)
    value = get(raw, key, "")
    return value isa AbstractString ? String(value) : ""
end

"""Bound attributed display names; a text marker must already fit before recognition."""
function chat_attribution(kind, name; bounded_marker::Bool=false)
    kind in ("person", "row") || return nothing
    name isa AbstractString || return nothing
    bounded_marker && ncodeunits(name) > 160 && return nothing
    cleaned = chat_clean_field(name, 160)
    isempty(cleaned) && return nothing
    return (kind == "person" ? "drawer" : "row", cleaned)
end

"""Recover own-app origin in metadata, customized username, then prefix order."""
function chat_own_origin(raw::AbstractDict, text::String)
    metadata = get(raw, "metadata", nothing)
    if metadata isa AbstractDict && get(metadata, "event_type", "") == "sot_chat_post"
        payload = get(metadata, "event_payload", nothing)
        if payload isa AbstractDict
            attribution = chat_attribution(get(payload, "kind", nothing), get(payload, "name", nothing))
            attribution === nothing || return (attribution..., text)
        end
    end
    username = chat_string(raw, "username")
    for kind in ("person", "row")
        suffix = " ($kind via Ship of Tools)"
        if endswith(username, suffix)
            name = chop(username; tail=length(suffix))
            attribution = chat_attribution(kind, name)
            attribution === nothing || return (attribution..., text)
        end
    end
    prefix = match(r"\A([^\r\n\p{Zl}\p{Zp}]+) \((person|row) via Ship of Tools\)(?:: |\z)", text)
    if prefix !== nothing
        attribution = chat_attribution(prefix.captures[2], prefix.captures[1]; bounded_marker=true)
        attribution === nothing || return (attribution..., String(chopprefix(text, prefix.match)))
    end
    return ("bot", "", text)
end

"""Return a MIME token without parameters, refusing URLs and recognizable secrets."""
function chat_file_mime(value::AbstractString)
    mime = lowercase(strip(first(split(value, ';'; limit=2))))
    valid = occursin(r"\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}\z", mime)
    secret = occursin(r"(?:xox[baprs]-|xapp-)", mime)
    return valid && !secret ? String(mime) : "application/octet-stream"
end

"""Summarize up to eight valid files without exposing private download URLs."""
function chat_message_files(raw::AbstractDict)
    files = Dict{String,Any}[]
    omitted = 0
    entries = get(raw, "files", nothing)
    entries isa AbstractVector || return files, omitted
    for entry in entries
        entry isa AbstractDict || continue
        id = get(entry, "id", nothing)
        chat_valid_id(id) || continue
        if length(files) == 8
            omitted += 1
            continue
        end
        stub = get(entry, "file_access", "") == "check_file_info"
        name = chat_clean_field(get(entry, "name", ""), 256)
        isempty(name) && (name = chat_clean_field(get(entry, "title", ""), 256))
        size = get(entry, "size", nothing)
        bytes = size isa Integer && !(size isa Bool) && 0 <= size <= typemax(Int) ? Int(size) : nothing
        push!(files, Dict{String,Any}(
            "id" => String(id), "name" => stub ? "" : name,
            "mime" => stub ? "" : chat_file_mime(chat_string(entry, "mimetype")),
            "bytes" => stub ? nothing : bytes,
            "thumbnail" => !stub && any(k -> get(entry, k, nothing) isa AbstractString,
                                         ("thumb_360", "thumb_480", "thumb_160", "thumb_720"))))
    end
    return files, omitted
end

"""
    normalize_message(ws, raw::AbstractDict, channel) -> Union{Dict{String,Any},Nothing}

Build the shared bounded record, retaining members and bots. Own-app identity is
checked before attribution markers. Invalid channel, timestamp or author identity
fields omit the record instead of failing a history page or shortening identities.
"""
function normalize_message(ws::ChatWorkspace, raw::AbstractDict, channel::AbstractString)
    ts = get(raw, "ts", nothing)
    chat_valid_ts(ts) && chat_valid_id(channel) || return nothing
    thread_ts = get(raw, "thread_ts", ts)
    chat_valid_ts(thread_ts) || return nothing
    latest_reply = get(raw, "latest_reply", nothing)
    haskey(raw, "latest_reply") && !chat_valid_ts(latest_reply) && return nothing
    for field in ("user", "bot_id")
        haskey(raw, field) && !chat_valid_id(get(raw, field, nothing)) && return nothing
    end
    text = chat_string(raw, "text")
    user = chat_string(raw, "user")
    bot = chat_string(raw, "bot_id")
    own = (!isempty(ws.bot_id) && bot == ws.bot_id) ||
          (!isempty(ws.bot_user_id) && user == ws.bot_user_id)
    origin, name = "member", ""
    if own
        origin, name, text = chat_own_origin(raw, text)
        author_id = ws.bot_user_id
    elseif haskey(raw, "bot_id") || get(raw, "subtype", "") == "bot_message"
        origin = "bot"
        author_id = bot
    else
        author_id = user
    end
    isempty(author_id) || chat_valid_id(author_id) || return nothing
    if isempty(name) && origin == "bot"
        name = chat_clean_field(get(raw, "username", ""), 160)
        profile = get(raw, "bot_profile", nothing)
        isempty(name) && profile isa AbstractDict && (name = chat_clean_field(get(profile, "name", ""), 160))
        isempty(name) && (name = "bot")
    elseif origin == "member"
        name = resolve_name!(ws, author_id)
    end
    files, files_omitted = chat_message_files(raw)
    count = get(raw, "reply_count", 0)
    reply_count = count isa Integer && !(count isa Bool) && 0 <= count <= typemax(Int) ? Int(count) : 0
    record = Dict{String,Any}(
        "workspace" => ws.id, "channel" => String(channel), "ts" => String(ts), "thread_ts" => String(thread_ts),
        "author" => Dict{String,Any}("id" => author_id, "name" => chat_clean_field(name, 160)),
        "origin" => origin, "text" => chat_bounded_text(text, 8192),
        "truncated" => ncodeunits(text) > 8192, "reply_count" => reply_count, "files" => files)
    if haskey(raw, "latest_reply")
        record["latest_reply"] = String(latest_reply)
    end
    files_omitted > 0 && (record["files_omitted"] = files_omitted)
    while ncodeunits(JSON.json(record)) > 32768
        record["text"] = chat_bounded_text(record["text"], div(ncodeunits(record["text"]), 2))
        record["truncated"] = true
    end
    return record
end

"""Sortable exact decimal timestamp key, including unequal-width integer parts."""
function chat_ts_key(ts::AbstractString)
    whole, fraction = split(ts, '.'; limit=2)
    whole = lstrip(whole, '0')
    return (length(whole), whole, rpad(fraction, 10, '0'))
end

"""Validate the complete history query independently of its continuation cursor."""
function chat_history_query(req::AbstractDict)
    query = Dict{String,Any}("channel" => chat_validate(get(req, "channel", nothing), "channel"))
    for field in ("thread_ts", "before", "after", "until")
        value = get(req, field, nothing)
        query[field] = value === nothing ? nothing : chat_validate(value, field; timestamp=true)
    end
    query["before"] !== nothing && query["until"] !== nothing &&
        throw(ChatError(:bad_request, "before and until cannot be combined"))
    limit = get(req, "limit", 20)
    limit isa Integer && !(limit isa Bool) && 1 <= limit <= 20 ||
        throw(ChatError(:bad_request, "Invalid limit"))
    query["limit"] = Int(limit)
    return query
end

"""Decode a bounded continuation and require its exact original query."""
function chat_decode_cursor(cursor, query::AbstractDict)
    cursor isa AbstractString || throw(ChatError(:bad_request, "Invalid cursor"))
    ncodeunits(cursor) <= 1024 || throw(ChatError(:incomplete_history, "History cursor exceeds 1024 bytes"))
    isempty(cursor) && return ""
    try
        decoded = JSON.parse(String(base64decode(cursor)))
        decoded isa AbstractDict || throw(ChatError(:bad_request, "Invalid cursor"))
        version = get(decoded, "v", nothing)
        version isa Integer && !(version isa Bool) && version == 1 ||
            throw(ChatError(:bad_request, "Invalid cursor version"))
        original = get(decoded, "q", nothing)
        original isa AbstractDict && chat_history_query(original) == query &&
            Set(keys(original)) == Set(keys(query)) ||
            throw(ChatError(:bad_request, "Cursor query does not match"))
        slack_cursor = get(decoded, "c", nothing)
        slack_cursor isa AbstractString && !isempty(slack_cursor) ||
            throw(ChatError(:bad_request, "Invalid Slack cursor"))
        return String(slack_cursor)
    catch e
        e isa ChatError && rethrow()
        throw(ChatError(:bad_request, "Invalid cursor encoding"))
    end
end

"""Encode the query and Slack continuation, refusing oversized continuations."""
function chat_encode_cursor(query::AbstractDict, slack_cursor::AbstractString)
    cursor = base64encode(JSON.json(Dict{String,Any}("v" => 1, "q" => query, "c" => slack_cursor)))
    ncodeunits(cursor) <= 1024 || throw(ChatError(:incomplete_history, "History cursor exceeds 1024 bytes"))
    return cursor
end

"""Check all exclusive/inclusive bounds client-side, including a thread's parent."""
function chat_inside_bounds(ts::AbstractString, query::AbstractDict)
    key = chat_ts_key(ts)
    query["after"] !== nothing && key <= chat_ts_key(query["after"]) && return false
    query["before"] !== nothing && key >= chat_ts_key(query["before"]) && return false
    query["until"] !== nothing && key > chat_ts_key(query["until"]) && return false
    return true
end

"""
    chat_history(ws, req::AbstractDict) -> Dict{String,Any}

Fetch one complete page, sorted ascending by exact timestamp. Channel pages walk
backward (the next cursor gives older messages); thread pages walk forward from
the parent, which may be included in addition to the requested reply limit.
Continuations bind every query field, and any failed or incomplete call fails the
entire request, even when Slack supplied some messages. A limited flag marks
history withheld by the workspace plan without preventing pagination.
"""
function chat_history(ws::ChatWorkspace, req::AbstractDict)
    query = chat_history_query(req)
    cursor = chat_decode_cursor(get(req, "cursor", ""), query)
    params = Dict{String,Any}("channel" => query["channel"], "limit" => query["limit"],
                              "include_all_metadata" => true)
    thread = query["thread_ts"] !== nothing
    thread && (params["ts"] = query["thread_ts"])
    isempty(cursor) || (params["cursor"] = cursor)
    query["after"] === nothing || (params["oldest"] = query["after"])
    if query["before"] !== nothing
        params["latest"] = query["before"]
        params["inclusive"] = false
    elseif query["until"] !== nothing
        params["latest"] = query["until"]
        params["inclusive"] = true
    else
        params["inclusive"] = false
    end
    data = chat_api(ws, "GET", thread ? "conversations.replies" : "conversations.history"; query=params)
    metadata = get(data, "response_metadata", nothing)
    next_cursor = metadata isa AbstractDict ? get(metadata, "next_cursor", "") : ""
    next_cursor isa AbstractString || throw(ChatError(:incomplete_history, "Invalid Slack continuation"))
    if get(data, "has_more", false) === true && isempty(next_cursor)
        throw(ChatError(:incomplete_history, "Slack omitted a required history cursor"))
    end
    result = Dict{String,Any}()
    get(data, "is_limited", false) === true && (result["limited"] = true)
    isempty(next_cursor) || (result["next_cursor"] = chat_encode_cursor(query, next_cursor))
    raw_messages = get(data, "messages", nothing)
    raw_messages isa AbstractVector || throw(ChatError(:io_error, "Invalid Slack messages array"))
    has_parent = thread && any(raw -> raw isa AbstractDict &&
        get(raw, "ts", nothing) == query["thread_ts"], raw_messages)
    page_limit = query["limit"] + (has_parent ? 1 : 0)
    length(raw_messages) <= page_limit ||
        throw(ChatError(:incomplete_history, "Slack history page exceeds requested limit"))
    messages = Dict{String,Any}[]
    omitted = 0
    for raw in raw_messages
        if !(raw isa AbstractDict) || !chat_valid_ts(get(raw, "ts", nothing))
            omitted += 1
            continue
        end
        chat_inside_bounds(raw["ts"], query) || continue
        message = normalize_message(ws, raw, query["channel"])
        if message === nothing
            omitted += 1
        else
            push!(messages, message)
        end
    end
    sort!(messages; by=m -> chat_ts_key(m["ts"]))
    result["messages"] = messages
    omitted > 0 && (result["omitted"] = omitted)
    return result
end

"""Validate an author once and share the recoverable label with posts and file shares."""
function chat_author_label(author)
    author isa AbstractDict || throw(ChatError(:bad_request, "Author is required"))
    kind = get(author, "kind", nothing)
    kind in ("person", "row") || throw(ChatError(:bad_request, "Invalid author kind"))
    raw_name = get(author, "name", nothing)
    raw_name isa AbstractString && ncodeunits(raw_name) <= 160 ||
        throw(ChatError(:bad_request, "Invalid author name"))
    name = clean_field(raw_name)
    isempty(name) && throw(ChatError(:bad_request, "Author name is required"))
    kind == "row" && !startswith(name, "@") && (name = "@" * name)
    ncodeunits(name) <= 160 || throw(ChatError(:bad_request, "Author name exceeds 160 bytes"))
    return kind, name, "$name ($kind via Ship of Tools)"
end

"""
    chat_post(ws, req::AbstractDict) -> Dict{String,Any}

Post once with recoverable person/row attribution in metadata and the workspace's
chosen author form. Return a timestamp only after Slack acknowledges; every
failure carries a definite refusal or an unknown outcome.
"""
function chat_post(ws::ChatWorkspace, req::AbstractDict)
    try
        channel = chat_validate(get(req, "channel", nothing), "channel")
        thread_ts = get(req, "thread_ts", nothing)
        thread_ts === nothing || (thread_ts = chat_validate(thread_ts, "thread_ts"; timestamp=true))
        text = get(req, "text", nothing)
        text isa AbstractString && !isempty(strip(text)) || throw(ChatError(:bad_request, "Text is required"))
        ncodeunits(text) <= 8192 || throw(ChatError(:too_large, "Text exceeds 8192 bytes"))
        kind, name, label = chat_author_label(get(req, "author", nothing))
        body = Dict{String,Any}("channel" => channel,
            "text" => ws.posting_form == :prefix ? "$label: $text" : String(text),
            "metadata" => Dict{String,Any}("event_type" => "sot_chat_post",
                "event_payload" => Dict{String,Any}("kind" => kind, "name" => name)))
        thread_ts === nothing || (body["thread_ts"] = thread_ts)
        ws.posting_form == :custom && (body["username"] = label)
        data = chat_api(ws, "POST", "chat.postMessage"; body, mutation=true)
        ts = get(data, "ts", nothing)
        chat_valid_ts(ts) || throw(ChatError(:io_error, "Slack omitted a valid post timestamp", nothing, :unknown))
        return Dict{String,Any}("ts" => String(ts))
    catch e
        throw(chat_exception(e; mutation=true))
    end
end
