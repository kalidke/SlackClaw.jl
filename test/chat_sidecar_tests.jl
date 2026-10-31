# These helpers refer to new SlackClaw names only inside function bodies. Each
# testset therefore fails at runtime on the base commit, rather than at load.

"""Encode a fake Slack object, or return an already constructed HTTP response."""
function chat_test_response(value; status=200, headers=Pair{String,String}[])
    value isa AbstractDict || return value
    return SlackClaw.ChatHTTPResponse(status, headers, collect(codeunits(SlackClaw.JSON.json(value))))
end

"""Decode URL query fields independently of the chat client's cursor code."""
function chat_test_query(url::String)
    fields = Dict{String,String}()
    query = split(url, '?'; limit=2)
    length(query) == 1 && return fields
    for field in split(query[2], '&')
        key, value = split(field, '='; limit=2)
        fields[SlackClaw.HTTP.URIs.unescapeuri(key)] = SlackClaw.HTTP.URIs.unescapeuri(value)
    end
    return fields
end

"""Record requests and answer them from a handler, with the real transport signature."""
function chat_test_transport(handler::Function)
    calls = Dict{String,Any}[]
    transport = function(method::String, url::String, headers::Vector{Pair{String,String}};
                         body=nothing, response_stream=nothing, timeout_s::Real=20)
        call = Dict{String,Any}("method" => method, "url" => url, "headers" => copy(headers),
            "query" => chat_test_query(url), "body" => body isa AbstractString ? SlackClaw.JSON.parse(body) : body,
            "timeout_s" => timeout_s, "response_stream" => response_stream)
        push!(calls, call)
        answer = handler(call)
        answer isa Exception && throw(answer)
        response = chat_test_response(answer)
        if response_stream !== nothing
            sink = response_stream(response.status, response.headers)
            if sink !== nothing
                # Small chunks exercise the bounded sink across multiple writes.
                for first_byte in 1:3:length(response.body)
                    write(sink, response.body[first_byte:min(first_byte + 2, length(response.body))])
                end
            end
            return SlackClaw.ChatHTTPResponse(response.status, response.headers, UInt8[])
        end
        return response
    end
    return transport, calls
end

"""Answer requests from a finite script; an unexpected extra request fails loudly."""
function chat_test_script(answers::AbstractVector)
    pending = Any[answers...]
    return chat_test_transport() do call
        isempty(pending) && error("Unexpected extra chat transport call")
        return popfirst!(pending)
    end
end

"""Capture a failure for assertions on its code, detail and mutation outcome."""
function chat_test_error(f::Function)
    try
        f()
    catch e
        return e
    end
    error("Expected a chat failure")
end

"""Build only the timeout constructor provided by the installed HTTP version."""
chat_test_timeout() = pkgversion(SlackClaw.HTTP).major >= 2 ?
    SlackClaw.HTTP.TimeoutError("request", 20_000_000_000) : SlackClaw.HTTP.TimeoutError(20)

"""Compare fixture timestamps using exact integers, independently of production code."""
function chat_test_time(ts::AbstractString)
    whole, fraction = split(ts, '.'; limit=2)
    return parse(BigInt, whole) * big(10)^10 + parse(BigInt, rpad(fraction, 10, '0'))
end

"""A scripted Slack with history, threads and users, including an out-of-bounds parent."""
function chat_test_slack(channel_messages::AbstractVector, thread_messages::AbstractVector)
    return chat_test_transport() do call
        endpoint = first(split(last(split(call["url"], '/')), '?'))
        query = call["query"]
        if endpoint == "users.info"
            return Dict{String,Any}("ok" => true, "user" => Dict{String,Any}(
                "name" => "login", "profile" => Dict{String,Any}("display_name" => "Keith")))
        end
        @test endpoint in ("conversations.history", "conversations.replies")
        @test call["method"] == "GET"
        @test query["include_all_metadata"] == "true"
        source = endpoint == "conversations.history" ? channel_messages : thread_messages
        inclusive = get(query, "inclusive", "false") == "true"
        candidates = filter(source) do message
            ts = chat_test_time(message["ts"])
            lower = !haskey(query, "oldest") || (inclusive ? ts >= chat_test_time(query["oldest"]) :
                                                           ts > chat_test_time(query["oldest"]))
            upper = !haskey(query, "latest") || (inclusive ? ts <= chat_test_time(query["latest"]) :
                                                           ts < chat_test_time(query["latest"]))
            return lower && upper
        end
        if endpoint == "conversations.replies" && !isempty(source) && !(first(source) in candidates)
            push!(candidates, first(source))
        end
        sort!(candidates; by=m -> chat_test_time(m["ts"]), rev=endpoint == "conversations.history")
        # Spaces, plus and slash force the client to escape Slack's opaque cursor.
        offset = haskey(query, "cursor") ? parse(Int, first(split(query["cursor"], ' '))) : 0
        limit = parse(Int, query["limit"])
        page = candidates[(offset + 1):min(offset + limit, length(candidates))]
        more = offset + length(page) < length(candidates)
        return Dict{String,Any}("ok" => true, "messages" => page, "has_more" => more,
            "response_metadata" => Dict{String,Any}("next_cursor" => more ? "$(offset + limit) +/" : ""))
    end
end

@testset "chat_history_pages_channel_and_thread_without_skipping" begin
    workspace = SlackClaw.ChatWorkspace
    history = SlackClaw.chat_history
    channel_messages = [Dict{String,Any}("ts" => "$(1000 + i).000001", "user" => "U1", "text" => "post $i")
                        for i in 1:45]
    thread_messages = [Dict{String,Any}("ts" => "$(1100 + i).000001", "thread_ts" => "1100.000001",
                        "user" => "U1", "text" => "reply $i") for i in 0:30]
    transport, calls = chat_test_slack(channel_messages, thread_messages)
    ws = workspace(id="T1", bot_token="fake-chat-token", transport=transport)
    request = Dict{String,Any}("channel" => "C1", "limit" => 20)
    pages = Any[]
    for _ in 1:3
        page = history(ws, request)
        push!(pages, page)
        timestamps = [m["ts"] for m in page["messages"]]
        @test all(ts -> ts isa String, timestamps)
        @test issorted(timestamps; by=chat_test_time)
        haskey(page, "next_cursor") && (request["cursor"] = page["next_cursor"])
    end
    @test [length(p["messages"]) for p in pages] == [20, 20, 5]
    timestamps = [m["ts"] for p in pages for m in p["messages"]]
    @test length(unique(timestamps)) == 45
    @test Set(timestamps) == Set(m["ts"] for m in channel_messages)
    @test chat_test_time(pages[2]["messages"][end]["ts"]) < chat_test_time(pages[1]["messages"][1]["ts"])
    @test chat_test_time(pages[3]["messages"][end]["ts"]) < chat_test_time(pages[2]["messages"][1]["ts"])
    @test !haskey(pages[end], "next_cursor")
    @test !haskey(pages[end], "omitted")
    @test all(p -> !haskey(p, "limited"), pages)
    @test count(c -> occursin("users.info", c["url"]), calls) == 1
    @test any(c -> occursin("%2B%2F", uppercase(c["url"])) && get(c["query"], "cursor", "") == "20 +/", calls)

    # Plan limits are additive page information, including on the final page.
    for limited in (true, false)
        fake, recorded = chat_test_script([Dict("ok" => true, "is_limited" => limited,
            "has_more" => false, "messages" => [Dict("ts" => "1.0", "bot_id" => "B1", "text" => "visible")])])
        limited_ws = workspace(id="T1", bot_token="fake", transport=fake)
        page = history(limited_ws, Dict("channel" => "C1"))
        @test [m["text"] for m in page["messages"]] == ["visible"]
        @test limited ? page["limited"] === true : !haskey(page, "limited")
        @test !haskey(page, "next_cursor")
        @test length(recorded) == 1
    end

    request = Dict{String,Any}("channel" => "C1", "thread_ts" => "1100.000001", "limit" => 20)
    first_page = history(ws, request)
    request["cursor"] = first_page["next_cursor"]
    last_page = history(ws, request)
    @test length(first_page["messages"]) == 20
    @test length(last_page["messages"]) == 11
    @test first_page["messages"][1]["ts"] == "1100.000001"
    @test first_page["messages"][end]["ts"] == "1119.000001"
    @test last_page["messages"][1]["ts"] == "1120.000001"
    @test !haskey(last_page, "next_cursor")
    @test [m["ts"] for p in (first_page, last_page) for m in p["messages"]] == [m["ts"] for m in thread_messages]

    # A replies page can contain the parent in addition to the requested replies.
    full_thread = thread_messages[1:21]
    fake, recorded = chat_test_script([Dict("ok" => true, "messages" => full_thread)])
    thread_ws = workspace(id="T1", bot_token="fake", transport=fake)
    page = history(thread_ws, Dict("channel" => "C1", "thread_ts" => "1100.000001", "limit" => 20))
    @test length(page["messages"]) == 21
    @test [m["ts"] for m in page["messages"]] == [m["ts"] for m in full_thread]
    @test recorded[1]["query"]["limit"] == "20"
    for (messages, fields) in ((full_thread, Dict{String,Any}()),
                               (thread_messages[2:22], Dict("thread_ts" => "1100.000001")),
                               (thread_messages[1:22], Dict("thread_ts" => "1100.000001")))
        fake, _ = chat_test_script([Dict("ok" => true, "messages" => messages)])
        oversized_ws = workspace(id="T1", bot_token="fake", transport=fake)
        err = chat_test_error(() -> history(oversized_ws, merge(Dict("channel" => "C1", "limit" => 20), fields)))
        @test err isa SlackClaw.ChatError
        @test err.code == :incomplete_history
    end

    cursor = pages[1]["next_cursor"]
    for (field, value) in ("channel" => "C2", "limit" => 19, "thread_ts" => "1100.000001",
                           "after" => "1.0", "before" => "2000.0", "until" => "2000.0")
        changed = Dict{String,Any}("channel" => "C1", "limit" => 20, "cursor" => cursor, field => value)
        n = length(calls)
        err = chat_test_error(() -> history(ws, changed))
        @test err isa SlackClaw.ChatError
        @test err.code == :bad_request
        @test length(calls) == n
    end
    for bad_cursor in ("%not-base64%", SlackClaw.base64encode("[]"), SlackClaw.base64encode("{}"))
        err = chat_test_error(() -> history(ws, Dict("channel" => "C1", "cursor" => bad_cursor)))
        @test err.code == :bad_request
    end

    for (upper, expected) in (("until", ["$i.000001" for i in 1011:1020]),
                              ("before", ["$i.000001" for i in 1011:1019]))
        bounded = history(ws, Dict("channel" => "C1", "after" => "1010.000001", upper => "1020.000001"))
        @test [m["ts"] for m in bounded["messages"]] == expected
        @test !haskey(bounded, "next_cursor")
    end
    @test isempty(history(ws, Dict("channel" => "C1", "after" => "1010.000001", "until" => "1010.000001"))["messages"])
    bounded = history(ws, Dict("channel" => "C1", "thread_ts" => "1100.000001",
                               "after" => "1105.000001", "until" => "1110.000001"))
    @test [m["ts"] for m in bounded["messages"]] == ["$i.000001" for i in 1106:1110]
    bounded = history(ws, Dict("channel" => "C1", "thread_ts" => "1100.000001", "before" => "1102.000001"))
    @test [m["ts"] for m in bounded["messages"]] == ["1100.000001", "1101.000001"]

    for fields in (Dict("before" => "2.0", "until" => "3.0"), Dict("limit" => 0), Dict("limit" => 21),
                   Dict("limit" => true), Dict("limit" => 1.5), Dict("thread_ts" => 1.0),
                   Dict("after" => "1e3"), Dict("channel" => "C_bad"), Dict("channel" => "C1\n"))
        request = merge(Dict{String,Any}("channel" => "C1"), fields)
        err = chat_test_error(() -> history(ws, request))
        @test err.code == :bad_request
    end
    for (response, expected) in (
        (Dict("ok" => true, "messages" => Any[], "has_more" => true), :incomplete_history),
        (Dict("ok" => true, "messages" => Any[], "has_more" => true,
              "response_metadata" => Dict("next_cursor" => "")), :incomplete_history),
        (Dict("ok" => true, "messages" => Any[], "response_metadata" => Dict("next_cursor" => "x"^1024)), :incomplete_history),
        (Dict("ok" => true, "messages" => nothing), :io_error),
        (Dict("ok" => true, "messages" => channel_messages), :incomplete_history))
        fake, recorded = chat_test_script([response])
        broken = workspace(id="T1", bot_token="fake", transport=fake)
        err = chat_test_error(() -> history(broken, Dict("channel" => "C1")))
        @test err isa SlackClaw.ChatError
        @test err.code == expected
        @test length(recorded) == 1
    end
    err = chat_test_error(() -> history(ws, Dict("channel" => "C1", "cursor" => "x"^1025)))
    @test err.code == :incomplete_history

    # A nonempty Slack continuation keeps even an empty page resumable.
    fake, recorded = chat_test_script([
        Dict("ok" => true, "messages" => Any[], "has_more" => false, "response_metadata" => Dict("next_cursor" => "next")),
        Dict("ok" => false, "error" => "internal_error")])
    empty_ws = workspace(id="T1", bot_token="fake", transport=fake)
    empty_page = history(empty_ws, FakeJSONObject("channel" => "C1"))
    @test isempty(empty_page["messages"])
    @test haskey(empty_page, "next_cursor")
    err = chat_test_error(() -> history(empty_ws, Dict("channel" => "C1", "cursor" => empty_page["next_cursor"])))
    @test err.code == :unavailable
    @test length(recorded) == 2

    # Slack may ignore bounds; compare unequal-width and very precise timestamps locally.
    precise = ["10.0", "9.9999999999", "12345678901234567890.0000000002", "12345678901234567890.0000000001"]
    fake, _ = chat_test_script([Dict("ok" => true, "messages" =>
        [Dict("ts" => ts, "bot_id" => "B1") for ts in precise])])
    precise_ws = workspace(id="T1", bot_token="fake", transport=fake)
    page = history(precise_ws, Dict("channel" => "C1", "after" => "9.9999999999",
                                   "until" => "12345678901234567890.0000000001"))
    @test [m["ts"] for m in page["messages"]] == ["10.0", "12345678901234567890.0000000001"]
end

@testset "chat_rate_limits_return_and_unknown_mutations_are_not_retried" begin
    workspace = SlackClaw.ChatWorkspace
    http_v2 = pkgversion(SlackClaw.HTTP).major >= 2
    # Exercise the real HTTP wrapper with fractional seconds and a local server.
    @test_logs min_level=Base.CoreLogging.Warn begin
        connections = String[]
        server = SlackClaw.HTTP.serve!(request -> begin
            push!(connections, SlackClaw.HTTP.header(request, "Connection", ""))
            SlackClaw.HTTP.Response(200, "local response")
        end, "127.0.0.1", 0; listenany=true, verbose=(http_v2 ? false : -1))
        try
            url = "http://127.0.0.1:$(SlackClaw.HTTP.port(server))/"
            # The first request also warms the server before testing a subsecond value.
            for (timeout_s, headers) in ((20.5, Pair{String,String}[]),
                                         (0.25, ["Connection" => "close"]),
                                         (0.25, ["cOnNeCtIoN" => "keep-alive"]))
                original_headers = copy(headers)
                response = SlackClaw.http_transport("GET", url, headers; timeout_s)
                @test response.status == 200
                @test String(response.body) == "local response"
                @test headers == original_headers
            end
            @test connections == [http_v2 ? "close" : "", "close", "keep-alive"]

            stream = IOBuffer()
            response = SlackClaw.http_transport("GET", url, Pair{String,String}[];
                                               response_stream=stream, timeout_s=20.5)
            @test response.status == 200
            @test isempty(response.body)
            @test String(take!(stream)) == "local response"
        finally
            close(server)
        end
    end

    token = "fake-chat-token-do-not-print"
    app_token = "fake-app-token-do-not-print"
    rate_limit = SlackClaw.ChatHTTPResponse(429, ["rEtRy-AfTeR" => "7"], UInt8[])
    fake, calls = chat_test_script([rate_limit, rate_limit])
    ws = workspace(id="T1", bot_token=token, app_token=app_token, transport=fake)
    request = Dict("channel" => "C1")
    fetch = () -> SlackClaw.chat_history(ws, request)
    chat_test_error(fetch) # Warm compilation before measuring the no-wait behavior.
    empty!(calls)
    err = nothing
    elapsed = @elapsed err = chat_test_error(fetch)
    @test elapsed < 0.75
    @test err isa SlackClaw.ChatError
    @test err.code == :rate_limited
    @test err.retry_after_s == 7
    @test err.outcome == :none
    @test length(calls) == 1
    payload = SlackClaw.chat_error_payload(err)
    @test payload == Dict{String,Any}("code" => "rate_limited", "error" => err.detail, "retry_after_s" => 7)
    @test !(haskey(payload, "outcome"))
    @test ("Authorization" => "Bearer $token") in calls[1]["headers"]

    post = Dict{String,Any}("channel" => "C1", "thread_ts" => "1.0", "text" => "hello",
                            "author" => Dict("kind" => "person", "name" => "Keith"))
    errors = Any[
        (SlackClaw.HTTP.ConnectError("https://slack.com/$token", ErrorException(token)), :unavailable, :refused),
        (Base.IOError(token, Int32(1)), :io_error, :unknown),
        (EOFError(), :io_error, :unknown),
        (ErrorException(token), :io_error, :unknown),
        (SlackClaw.ChatHTTPResponse(500, Pair{String,String}[], collect(codeunits(token))), :unavailable, :unknown),
        (SlackClaw.ChatHTTPResponse(403, Pair{String,String}[], collect(codeunits(token))), :bad_request, :refused),
        (SlackClaw.ChatHTTPResponse(200, Pair{String,String}[], collect(codeunits(token))), :io_error, :unknown),
        (SlackClaw.ChatHTTPResponse(200, Pair{String,String}[], collect(codeunits("[]"))), :io_error, :unknown),
        (Dict("ts" => "1.0"), :io_error, :unknown),
        (Dict("ok" => nothing, "ts" => "1.0"), :io_error, :unknown),
        (Dict("ok" => false, "error" => "channel_not_found"), :not_found, :refused),
        (Dict("ok" => false, "error" => "internal_error"), :unavailable, :unknown),
        (Dict("ok" => false, "error" => token * "\n" * app_token), :bad_request, :refused),
        (Dict("ok" => true), :io_error, :unknown),
        (rate_limit, :rate_limited, :refused)]
    if http_v2
        append!(errors, [
            (SlackClaw.HTTP.TimeoutError("request", 20_000_000_000), :timeout, :unknown),
            (SlackClaw.HTTP.TimeoutError("connect", 10_000_000_000), :timeout, :unknown),
            (SlackClaw.HTTP.TimeoutError("tls_handshake", 10_000_000_000), :timeout, :unknown),
            (SlackClaw.HTTP.DNSError(token, ErrorException(token)), :unavailable, :refused),
            (SlackClaw.HTTP.ParseError(token), :io_error, :unknown),
            (SlackClaw.HTTP.ProtocolError(token), :io_error, :unknown),
            (SlackClaw.HTTP.TLSHandshakeError(ErrorException(token)), :io_error, :unknown),
            (SlackClaw.HTTP.TLSTransportError(ErrorException(token)), :io_error, :unknown)])
    else
        push!(errors, (SlackClaw.HTTP.TimeoutError(20), :timeout, :unknown))
    end
    if isdefined(SlackClaw.HTTP, :RequestError)
        http_request = SlackClaw.HTTP.Request("POST", "/api/chat.postMessage", ["Authorization" => "Bearer $token"])
        append!(errors, [
            (SlackClaw.HTTP.RequestError(http_request, ErrorException(token)), :io_error, :unknown),
            (SlackClaw.HTTP.RequestError(http_request, chat_test_timeout()), :timeout, :unknown),
            (SlackClaw.HTTP.RequestError(http_request,
                SlackClaw.HTTP.ConnectError("https://slack.com/$token", ErrorException(token))), :unavailable, :refused)])
    end
    logger = Test.TestLogger()
    for (answer, code, outcome) in errors
        fake, recorded = chat_test_script([answer])
        broken = workspace(id="T1", bot_token=token, app_token=app_token, transport=fake)
        err = Base.CoreLogging.with_logger(logger) do
            chat_test_error(() -> SlackClaw.chat_post(broken, post))
        end
        @test err isa SlackClaw.ChatError
        @test err.code == code
        @test err.outcome == outcome
        @test length(recorded) == 1
        @test recorded[1]["timeout_s"] == 20
        payload = SlackClaw.chat_error_payload(err)
        @test payload["outcome"] == String(outcome)
        for rendered in (err.detail, SlackClaw.JSON.json(payload), sprint(show, err), sprint(showerror, err),
                         sprint(show, broken), sprint(show, MIME("text/plain"), broken))
            @test !occursin(token, rendered)
            @test !occursin(app_token, rendered)
        end
    end
    @test isempty(logger.logs)

    # Every mutation needs an explicit acknowledgement; reads keep Slack's mapping.
    for ok in (nothing, 0, 1, "true")
        for mutation in (true, false)
            fake, recorded = chat_test_script([Dict("ok" => ok, "error" => "channel_not_found", "ts" => "1.0")])
            unconfirmed = workspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> SlackClaw.chat_api(unconfirmed, "POST", "chat.postMessage"; mutation))
            @test err.code == (mutation ? :io_error : :not_found)
            @test err.outcome == (mutation ? :unknown : :none)
            @test length(recorded) == 1
        end
    end

    for header in (Pair{String,String}[], ["Retry-After" => "invalid"], ["Retry-After" => "-1"])
        fake, _ = chat_test_script([SlackClaw.ChatHTTPResponse(429, header, UInt8[])])
        limited = workspace(id="T1", bot_token=token, transport=fake)
        @test chat_test_error(() -> SlackClaw.chat_post(limited, post)).retry_after_s == 30
    end
    for (slack_error, code) in (
        "invalid_auth" => :unauthorized, "not_authed" => :unauthorized, "account_inactive" => :unauthorized,
        "token_revoked" => :unauthorized, "token_expired" => :unauthorized,
        "missing_scope" => :forbidden, "not_in_channel" => :forbidden, "restricted_action" => :forbidden,
        "is_archived" => :forbidden, "channel_is_archived" => :forbidden,
        "thread_not_found" => :not_found, "message_not_found" => :not_found, "file_not_found" => :not_found,
        "user_not_found" => :not_found, "ratelimited" => :rate_limited,
        "msg_too_long" => :too_large, "too_large" => :too_large, "fatal_error" => :unavailable,
        "request_timeout" => :unavailable, "service_unavailable" => :unavailable, "other" => :bad_request,
        "api_error.1" => :bad_request, "a"^64 => :bad_request)
        fake, recorded = chat_test_script([Dict("ok" => false, "error" => slack_error)])
        broken = workspace(id="T1", bot_token=token, transport=fake)
        err = chat_test_error(() -> SlackClaw.chat_post(broken, post))
        @test err.code == code
        @test err.detail == "Slack: $slack_error"
        @test err.outcome == (code == :unavailable ? :unknown : :refused)
        @test length(recorded) == 1
    end
    for slack_error in ("https://files.slack.com/files-pri/T1-F1/x.png?key=secret",
                        "", "a"^65, "bad\n", "UPPER", "bad-error")
        fake, recorded = chat_test_script([Dict("ok" => false, "error" => slack_error)])
        broken = workspace(id="T1", bot_token=token, transport=fake)
        err = chat_test_error(() -> SlackClaw.chat_post(broken, post))
        @test err.code == :bad_request
        @test err.outcome == :refused
        @test err.detail == "unexpected Slack error"
        @test length(recorded) == 1
        for rendered in (err.detail, repr(err), sprint(showerror, err),
                         SlackClaw.JSON.json(SlackClaw.chat_error_payload(err)))
            @test !occursin("https", rendered)
            @test !occursin("files-pri", rendered)
            @test !occursin("secret", rendered)
        end
    end
    bounded = SlackClaw.ChatError(:bad_request, "xoxb-fake-secret\n" * "é"^200)
    @test ncodeunits(bounded.detail) <= 256
    @test isvalid(bounded.detail)
    @test !occursin('\n', bounded.detail)
    @test !occursin("xoxb-fake-secret", sprint(show, bounded))

    fake, recorded = chat_test_script([
        Dict("ok" => true, "team_id" => "T1", "user_id" => "UBOT", "bot_id" => "BOWN"),
        Dict("ok" => true, "team_id" => "T2", "user_id" => "UOTHER", "bot_id" => "BOTHER")])
    authenticated = workspace(id="T1", bot_token=token, transport=fake)
    @test SlackClaw.chat_authenticate!(authenticated) === authenticated
    @test (authenticated.bot_user_id, authenticated.bot_id) == ("UBOT", "BOWN")
    @test chat_test_error(() -> SlackClaw.chat_authenticate!(authenticated)).code == :unauthorized
    @test (authenticated.bot_user_id, authenticated.bot_id) == ("UBOT", "BOWN")
    @test_throws ArgumentError workspace(id="T1", bot_token=token, posting_form=:other)
    @test_throws SlackClaw.ChatError workspace(id="T_bad", bot_token=token)

    # Local request failures also carry a mutation outcome, before any HTTP call.
    fake, recorded = chat_test_script(Any[])
    validated = workspace(id="T1", bot_token=token, transport=fake)
    for fields in (Dict("text" => ""), Dict("text" => "a"^8193), Dict("text" => "🙂"^2049),
                   Dict("channel" => "C"^65), Dict("thread_ts" => 1.0),
                   Dict("author" => Dict("kind" => "bot", "name" => "Keith")),
                   Dict("author" => Dict("kind" => "person", "name" => "\n")),
                   Dict("author" => Dict("kind" => "person", "name" => "é"^81)),
                   Dict("author" => Dict("kind" => "row", "name" => "x"^160)))
        err = chat_test_error(() -> SlackClaw.chat_post(validated, merge(post, fields)))
        @test err isa SlackClaw.ChatError
        @test err.outcome == :refused
        @test err.code == (haskey(fields, "text") && ncodeunits(fields["text"]) > 8192 ? :too_large : :bad_request)
    end
    @test isempty(recorded)
end

@testset "chat_origin_survives_history_and_bot_posts_remain_visible" begin
    workspace = SlackClaw.ChatWorkspace
    normalize = SlackClaw.normalize_message
    messages = Any[
        Dict{String,Any}("ts" => "1.0", "user" => "U1", "text" => "member", "reply_count" => 2, "latest_reply" => "7.0"),
        Dict{String,Any}("ts" => "2.0", "bot_id" => "BOWN", "user" => "UBOT", "text" => "Keith (person via Ship of Tools): hi"),
        Dict{String,Any}("ts" => "3.0", "bot_id" => "BOWN", "username" => "@worker (row via Ship of Tools)", "text" => "row"),
        Dict{String,Any}("ts" => "4.0", "user" => "UBOT", "text" => "metadata", "metadata" =>
            Dict("event_type" => "sot_chat_post", "event_payload" => Dict("kind" => "row", "name" => "@meta"))),
        Dict{String,Any}("ts" => "5.0", "bot_id" => "BOTHER", "bot_profile" => Dict("name" => "Other app"), "text" => "bot"),
        Dict{String,Any}("ts" => "6.0", "user" => "U1", "text" => "Keith (person via Ship of Tools): hi",
            "metadata" => Dict("event_type" => "sot_chat_post", "event_payload" => Dict("kind" => "person", "name" => "Forged")))]
    fake, calls = chat_test_slack(messages, Any[])
    ws = workspace(id="T1", bot_token="fake", transport=fake)
    ws.bot_user_id, ws.bot_id = "UBOT", "BOWN"
    page = SlackClaw.chat_history(ws, Dict("channel" => "C1"))
    records = page["messages"]
    @test length(records) == 6
    @test [m["origin"] for m in records] == ["member", "drawer", "row", "row", "bot", "member"]
    @test [m["author"]["name"] for m in records] == ["Keith", "Keith", "@worker", "@meta", "Other app", "Keith"]
    @test [m["author"]["id"] for m in records] == ["U1", "UBOT", "UBOT", "UBOT", "BOTHER", "U1"]
    @test records[2]["text"] == "hi"
    @test records[6]["text"] == "Keith (person via Ship of Tools): hi"
    @test records[1]["thread_ts"] == records[1]["ts"]
    @test records[1]["latest_reply"] == "7.0"
    @test records[1]["reply_count"] === 2
    @test records[2]["reply_count"] === 0
    @test count(c -> occursin("users.info", c["url"]), calls) == 1

    # Metadata wins over the other markers, with its display name bounded on output.
    attributed = Dict{String,Any}("ts" => "8.0", "bot_id" => "BOWN", "text" => "hi",
        "username" => "@worker (row via Ship of Tools)", "metadata" => Dict(
            "event_type" => "sot_chat_post", "event_payload" => Dict("kind" => "person", "name" => "é"^81)))
    record = normalize(ws, attributed, "C1")
    @test record["origin"] == "drawer"
    @test record["author"]["name"] == "é"^80
    attributed["text"] = "$("x"^161) (person via Ship of Tools): hi"
    delete!(attributed, "metadata")
    delete!(attributed, "username")
    @test normalize(ws, attributed, "C1")["origin"] == "bot"
    @test normalize(ws, attributed, "C1")["text"] == attributed["text"]

    for form in (:prefix, :custom), kind in ("person", "row")
        fake, posted = chat_test_script([Dict("ok" => true, "ts" => "10.000001")])
        poster = workspace(id="T1", bot_token="fake", posting_form=form, transport=fake)
        poster.bot_user_id, poster.bot_id = "UBOT", "BOWN"
        req = FakeJSONObject("channel" => "C1", "thread_ts" => "1.0", "text" => "hello", "author" =>
                             FakeJSONObject("kind" => kind, "name" => "worker\nname"))
        @test SlackClaw.chat_post(poster, req) == Dict("ts" => "10.000001")
        @test length(posted) == 1
        call = only(posted)
        body = call["body"]
        name = kind == "row" ? "@worker name" : "worker name"
        label = "$name ($kind via Ship of Tools)"
        @test call["method"] == "POST"
        @test endswith(call["url"], "/chat.postMessage")
        @test ("Content-Type" => "application/json; charset=utf-8") in call["headers"]
        @test body["thread_ts"] == "1.0"
        @test body["metadata"]["event_payload"]["name"] == name
        @test body["text"] == (form == :prefix ? "$label: hello" : "hello")
        @test form == :custom ? body["username"] == label : !haskey(body, "username")
        raw = Dict{String,Any}(String(k) => v for (k, v) in body)
        raw["ts"], raw["user"], raw["bot_id"] = "10.000001", "UBOT", "BOWN"
        record = normalize(poster, raw, "C1")
        @test record["origin"] == (kind == "person" ? "drawer" : "row")
        @test record["author"]["name"] == name
        # History without metadata must recover the same identity from either form.
        delete!(raw, "metadata")
        record = normalize(poster, raw, "C1")
        @test record["origin"] == (kind == "person" ? "drawer" : "row")
        @test record["author"]["name"] == name
        @test record["text"] == "hello"
    end

    raw = Dict{String,Any}("ts" => "20.0", "bot_id" => "BOTHER", "text" => "🙂"^2250)
    record = normalize(ws, raw, "C1")
    @test record["truncated"] === true
    @test ncodeunits(record["text"]) == 8192
    @test isvalid(record["text"])
    @test normalize(ws, FakeJSONObject("ts" => "21.0", "bot_id" => "BOTHER", "text" => nothing), "C1")["text"] == ""
    @test normalize(ws, FakeJSONObject("ts" => "21.0", "subtype" => "bot_message"), "C1")["origin"] == "bot"

    files = [Dict{String,Any}("id" => "F$i", "name" => "a\n" * "é"^200,
        "mimetype" => "m\t" * "é"^100, "size" => 12, "thumb_360" => "private-url") for i in 1:10]
    raw["files"] = Any[nothing, Dict("id" => "bad-id"), files...]
    record = normalize(ws, raw, "C1")
    @test length(record["files"]) == 8
    @test record["files_omitted"] == 2
    for file in record["files"]
        @test ncodeunits(file["name"]) <= 256
        @test ncodeunits(file["mime"]) <= 128
        @test isvalid(file["name"]) && isvalid(file["mime"])
        @test !occursin('\n', file["name"]) && !occursin('\t', file["mime"])
        @test file["bytes"] === 12
        @test file["thumbnail"] === true
        @test !occursin("private-url", SlackClaw.JSON.json(file))
    end
    for mime in ("https://cdn.example.org/private/key", "image/xoxb-fake")
        raw["files"] = [Dict("id" => "F1", "mimetype" => mime)]
        record = normalize(ws, raw, "C1")
        @test record["files"][1]["mime"] == "application/octet-stream"
    end
    raw["files"] = [Dict{String,Any}("id" => "F1", "file_access" => "check_file_info", "name" => "hidden", "size" => 12),
                    Dict{String,Any}("id" => "F2", "title" => "fallback", "size" => "12", "thumb_480" => "url")]
    record = normalize(ws, raw, "C1")
    @test record["files"][1]["name"] == ""
    @test record["files"][1]["bytes"] === nothing
    @test record["files"][2]["name"] == "fallback"
    @test record["files"][2]["bytes"] === nothing
    @test record["files"][2]["thumbnail"] === true
    @test !haskey(record, "files_omitted")

    raw["text"] = "\0"^8192
    raw["username"] = "é"^100 * "\nend"
    raw["files"] = files[1:8]
    record = normalize(ws, raw, "C1")
    @test ncodeunits(SlackClaw.JSON.json(record)) <= 32768
    @test record["truncated"] === true
    @test ncodeunits(record["text"]) < 8192
    @test ncodeunits(record["author"]["name"]) <= 160
    @test normalize(ws, Dict("ts" => "invalid"), "C1") === nothing
    @test normalize(ws, Dict("ts" => 1.0), "C1") === nothing
    @test normalize(ws, Dict("ts" => "1.0"), "C_bad") === nothing
    @test normalize(ws, Dict("ts" => "1.0\n"), "C1") === nothing
    for (field, value) in ("thread_ts" => "bogus", "latest_reply" => "bogus",
                           "user" => "bad id", "bot_id" => "bad id",
                           "thread_ts" => 1.0, "latest_reply" => nothing,
                           "user" => 12, "bot_id" => nothing)
        @test normalize(ws, FakeJSONObject("ts" => "1.0", field => value), "C1") === nothing
    end

    fake, _ = chat_test_script([Dict("ok" => true, "messages" => Any[
        Dict("ts" => "invalid"), Dict("ts" => "1.0", "bot_id" => "B1"), nothing])])
    omitted_ws = workspace(id="T1", bot_token="fake", transport=fake)
    page = SlackClaw.chat_history(omitted_ws, Dict("channel" => "C1"))
    @test length(page["messages"]) == 1
    @test page["omitted"] == 2

    fake, _ = chat_test_script([Dict("ok" => true, "messages" => Any[
        Dict("ts" => "1.0", "bot_id" => "B1"),
        Dict("ts" => "2.0", "thread_ts" => "bogus"),
        Dict("ts" => "3.0", "user" => "bad id"),
        Dict("ts" => "4.0", "bot_id" => "B1")])])
    omitted_ws = workspace(id="T1", bot_token="fake", transport=fake)
    page = SlackClaw.chat_history(omitted_ws, Dict("channel" => "C1"))
    @test [m["ts"] for m in page["messages"]] == ["1.0", "4.0"]
    @test page["omitted"] == 2

    rate_limit = SlackClaw.ChatHTTPResponse(429, ["Retry-After" => "7"], UInt8[])
    fake, recorded = chat_test_script([rate_limit, rate_limit,
        Dict("ok" => true, "user" => Dict("profile" => Dict("display_name" => "", "real_name" => "Real\nName"))),
        Dict("ok" => true, "user" => Dict("name" => "login"))])
    names_ws = workspace(id="T1", bot_token="fake", transport=fake)
    @test SlackClaw.resolve_name!(names_ws, "") == "unknown"
    @test SlackClaw.resolve_name!(names_ws, "U2") == "U2"
    @test !haskey(names_ws.names, "U2")
    @test SlackClaw.resolve_name!(names_ws, "U2") == "U2"
    @test SlackClaw.resolve_name!(names_ws, "U2") == "Real Name"
    @test SlackClaw.resolve_name!(names_ws, "U2") == "Real Name"
    @test SlackClaw.resolve_name!(names_ws, "U3") == "login"
    @test length(recorded) == 4

    # A slow users.info must not keep cached lookups waiting for the workspace lock.
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    fake, recorded = chat_test_transport() do call
        @test occursin("/users.info", call["url"])
        @test call["query"]["user"] == "USLOW"
        put!(started, nothing)
        take!(release)
        return Dict("ok" => true, "user" => Dict("profile" => Dict("display_name" => "Fresh Name")))
    end
    concurrent_ws = workspace(id="T1", bot_token="fake", transport=fake)
    concurrent_ws.names["UCACHED"] = "Cached Name"
    lookup = @async SlackClaw.resolve_name!(concurrent_ws, "USLOW")
    cached = nothing
    try
        @test timedwait(() -> isready(started) || istaskdone(lookup), 5.0) == :ok
        @test isready(started)
        cached = @async SlackClaw.resolve_name!(concurrent_ws, "UCACHED")
        @test timedwait(() -> istaskdone(cached), 1.0) == :ok
    finally
        put!(release, nothing)
    end
    @test fetch(lookup) == "Fresh Name"
    @test fetch(cached) == "Cached Name"
    @test length(recorded) == 1
end

@testset "chat_private_fetch_bounds_bytes_and_redirect_authorization" begin
    fetch_file = SlackClaw.chat_fetch_file
    response = SlackClaw.ChatHTTPResponse
    token = "fake-file-bot-token-do-not-print"
    original_url = "https://files.slack.com/private/$token/original"
    redirected_url = "https://files-origin.slack.com/private/$token/original"
    bytes = UInt8[0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x80, 0x0a, 0x0d, 0x42]
    file_info = Dict{String,Any}("id" => "F1", "channels" => ["C1"], "size" => length(bytes),
        "mimetype" => "image/png", "url_private_download" => original_url,
        "url_private" => "https://files.slack.com/fallback", "thumb_360" => "https://files.slack.com/small")
    download = response(200, ["Content-Type" => "image/png", "Content-Length" => string(length(bytes))], bytes)
    redirect(url) = response(302, ["Location" => url], collect(codeunits("discard this redirect body")))
    errors = Any[]
    mktempdir() do dir
        request(fields=Dict{String,Any}()) = merge(Dict{String,Any}("channel" => "C1", "file_id" => "F1",
            "variant" => "original", "destination" => tempname(dir), "max_bytes" => length(bytes)), fields)
        function scenario(answers; file=copy(file_info), fields=Dict{String,Any}())
            fake, calls = chat_test_script(Any[Dict("ok" => true, "file" => file), answers...])
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            return ws, calls, request(fields)
        end

        ws, calls, req = scenario([redirect(redirected_url), download])
        @test fetch_file(ws, req) == Dict("bytes" => length(bytes), "mime" => "image/png")
        @test read(req["destination"]) == bytes
        if Sys.isunix()
            @test (filemode(req["destination"]) & 0o777) == 0o600
        end
        @test [c["url"] for c in calls[2:end]] == [original_url, redirected_url]
        @test all(c -> ("Authorization" => "Bearer $token") in c["headers"], calls)
        @test all(c -> c["response_stream"] isa Function, calls[2:end])

        # Authorization is decided anew at every hop, including returning to Slack.
        cdn_url = "https://cdn.example.org/private/asset"
        ws, calls, req = scenario([redirect(cdn_url), redirect(redirected_url), download])
        @test fetch_file(ws, req)["bytes"] == length(bytes)
        @test read(req["destination"]) == bytes
        @test isempty(calls[3]["headers"])
        @test ("Authorization" => "Bearer $token") in calls[4]["headers"]
        for host in ("slack.com", "FILES.SLACK.COM", "slack.com.example.org", "evilslack.com")
            ws, calls, req = scenario([redirect("https://$host/asset"), download])
            fetch_file(ws, req)
            authorized = any(h -> lowercase(first(h)) == "authorization", calls[end]["headers"])
            @test authorized == (lowercase(host) in ("slack.com", "files.slack.com"))
        end

        ws, calls, req = scenario([redirect("../next?part=1"), download])
        fetch_file(ws, req)
        @test calls[end]["url"] == "https://files.slack.com/private/next?part=1"
        ws, calls, req = scenario([redirect("//cdn.example.org/relative"), download])
        fetch_file(ws, req)
        @test calls[end]["url"] == "https://cdn.example.org/relative"
        @test isempty(calls[end]["headers"])

        for url in ("http://cdn.example.org/$token", "https://user:secret@files.slack.com/file", "https://files.slack.com\\@evil.example/file")
            ws, calls, req = scenario([redirect(url)])
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err isa SlackClaw.ChatError
            @test err.code == :forbidden
            @test length(calls) == 2
            @test !ispath(req["destination"])
        end
        ws, calls, req = scenario([redirect(redirected_url) for _ in 1:6])
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :io_error
        @test length(calls) == 7 # files.info, initial GET, and five followed redirects.
        @test !ispath(req["destination"])
        ws, calls, req = scenario(vcat([redirect(redirected_url) for _ in 1:5], [download]))
        @test fetch_file(ws, req)["bytes"] == length(bytes)

        # Metadata and response lengths reject before any destination is created.
        ws, calls, req = scenario(Any[]; file=merge(file_info, Dict("size" => length(bytes) + 1)))
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :too_large
        @test length(calls) == 1
        @test !ispath(req["destination"])
        for length_header in (string(length(bytes) + 1), "9"^40)
            ws, calls, req = scenario([response(200, ["cOnTeNt-LeNgTh" => length_header], bytes)])
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err.code == :too_large
            @test !ispath(req["destination"])
        end
        ws, calls, req = scenario([response(200, Pair{String,String}[], vcat(bytes, [0x01]))])
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :too_large
        @test !ispath(req["destination"])
        ws, calls, req = scenario([response(200, ["cOnTeNt-TyPe" => "text/html; charset=utf-8"], bytes)])
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :unauthorized
        @test err.detail == "Slack returned a sign-in page instead of the file"
        @test !ispath(req["destination"])
        # Preserve callback errors and overflow flags through wrapping or a swallowed exception.
        for mode in (:wrapped, :swallowed), (answer, code) in (
            (response(200, ["Content-Length" => "99999"], bytes), :too_large),
            (response(200, ["Content-Type" => "text/html"], bytes), :unauthorized),
            (response(200, Pair{String,String}[], vcat(bytes, [0x01])), :too_large))
            fake, calls = chat_test_script(Any[Dict("ok" => true, "file" => file_info), answer])
            wrapped = function(method, url, headers; kwargs...)
                try
                    return fake(method, url, headers; kwargs...)
                catch
                    mode == :wrapped && error("wrapped $token $original_url")
                    return response(200, Pair{String,String}[], UInt8[])
                end
            end
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=wrapped)
            req = request()
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err.code == code
            @test !ispath(req["destination"])
        end
        ws, calls, req = scenario([download]; file=merge(file_info, Dict("mimetype" => "text/html")))
        @test fetch_file(ws, req)["mime"] == "text/html"
        # MIME fields can contain URLs or token-shaped strings, neither of
        # which may escape in the result, even though the latter is a token.
        for mime in ("https://cdn.example.org/private/key", "image/xoxb-fake",
                     "text", "image/", "image/" * "a"^65, "image/pn\ng")
            ws, calls, req = scenario([download]; file=merge(file_info, Dict("mimetype" => mime)))
            @test fetch_file(ws, req)["mime"] == "application/octet-stream"
            ws, calls, req = scenario([response(200, ["Content-Type" => mime], bytes)];
                fields=Dict("variant" => "thumbnail"))
            @test fetch_file(ws, req)["mime"] == "application/octet-stream"
        end
        ws, calls, req = scenario([download]; file=merge(file_info, Dict("mimetype" => "IMAGE/PNG; charset=binary")))
        @test fetch_file(ws, req)["mime"] == "image/png"

        existing = joinpath(dir, "existing")
        write(existing, "keep this")
        ws, calls, req = scenario(Any[]; fields=Dict("destination" => existing))
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :bad_request
        @test isempty(calls)
        @test read(existing, String) == "keep this"
        for target in (existing, joinpath(dir, "missing-target"))
            destination = tempname(dir)
            fake, calls = chat_test_transport() do call
                if occursin("/files.info?", call["url"])
                    return Dict("ok" => true, "file" => file_info)
                end
                symlink(target, destination) # Plant it after validation, before the exclusive create.
                return download
            end
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> fetch_file(ws, request(Dict("destination" => destination))))
            push!(errors, err)
            @test err.code == :bad_request
            @test islink(destination)
            @test readlink(destination) == target
            @test read(existing, String) == "keep this"
            @test !ispath(joinpath(dir, "missing-target"))
        end
        for substitute in (false, true)
            req = request()
            fake = function(method, url, headers; response_stream=nothing, kwargs...)
                response_stream === nothing && return chat_test_response(Dict("ok" => true, "file" => file_info))
                sink = response_stream(200, Pair{String,String}[])
                write(sink, bytes[1:3])
                if substitute
                    rm(req["destination"])
                    symlink(existing, req["destination"])
                end
                error("partial transfer failed $token $original_url")
            end
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err.code == :io_error
            if substitute
                @test islink(req["destination"])
                @test readlink(req["destination"]) == existing
                @test read(existing, String) == "keep this"
            else
                @test !ispath(req["destination"])
            end
        end

        for sharing in (Dict("groups" => ["C1"]), Dict("ims" => ["C1"]),
                        Dict("shares" => FakeJSONObject("public" => FakeJSONObject("C1" => Any[]))),
                        Dict("shares" => FakeJSONObject("private" => FakeJSONObject("C1" => Any[]))))
            file = merge(file_info, Dict("channels" => Any[]), sharing)
            ws, calls, req = scenario([download]; file)
            @test fetch_file(ws, req)["bytes"] == length(bytes)
        end
        ws, calls, req = scenario(Any[]; file=merge(file_info, Dict("channels" => ["COTHER"])))
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :forbidden
        @test length(calls) == 1
        @test !ispath(req["destination"])

        # An AbstractDict request and metadata also exercise the JSON v1 contract.
        thumb_headers = ["Content-Type" => "image/jpeg; charset=binary"]
        ws, calls, req = scenario([response(200, thumb_headers, bytes)];
            file=FakeJSONObject(pairs(merge(file_info, Dict("size" => 999999)))...), fields=Dict("variant" => "thumbnail"))
        @test fetch_file(ws, FakeJSONObject(pairs(req)...)) == Dict("bytes" => length(bytes), "mime" => "image/jpeg")
        @test calls[end]["url"] == file_info["thumb_360"]
        for (removed, expected) in ((["thumb_360"], "thumb_160"), (["thumb_360", "thumb_160"], "thumb_480"))
            file = merge(file_info, Dict("thumb_160" => "https://files.slack.com/160", "thumb_480" => "https://files.slack.com/480"))
            foreach(key -> delete!(file, key), removed)
            ws, calls, req = scenario([download]; file, fields=Dict("variant" => "thumbnail"))
            fetch_file(ws, req)
            @test calls[end]["url"] == file[expected]
        end
        file = copy(file_info)
        delete!(file, "url_private_download")
        ws, calls, req = scenario([download]; file)
        fetch_file(ws, req)
        @test calls[end]["url"] == file_info["url_private"]
        delete!(file, "url_private")
        ws, calls, req = scenario(Any[]; file)
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :not_found

        for (status, code) in ((401, :unauthorized), (403, :forbidden), (404, :not_found),
                               (429, :rate_limited), (503, :unavailable), (418, :io_error))
            ws, calls, req = scenario([response(status, ["Retry-After" => "9"], bytes)])
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err.code == code
            @test err.outcome == :none
            @test err.retry_after_s == (status == 429 ? 9 : nothing)
            @test !ispath(req["destination"])
        end
        for fields in (Dict("max_bytes" => 0), Dict("max_bytes" => true), Dict("max_bytes" => 1.5),
                       Dict("variant" => "small"), Dict("file_id" => "bad-id"), Dict("channel" => "bad-id"),
                       Dict("destination" => "relative"), Dict("destination" => "/" * "a"^4096),
                       Dict("destination" => joinpath(dir, "missing", "file")))
            ws, calls, req = scenario(Any[]; fields)
            err = chat_test_error(() -> fetch_file(ws, req))
            push!(errors, err)
            @test err.code == :bad_request
            @test isempty(calls)
        end
        ws, calls, req = scenario([ErrorException("$token $original_url")])
        err = chat_test_error(() -> fetch_file(ws, req))
        push!(errors, err)
        @test err.code == :io_error
        ws, calls, req = scenario(Any[]; file=file_info)
        ws.transport, _ = chat_test_script([Dict("ok" => false, "error" => "failure $original_url")])
        push!(errors, chat_test_error(() -> fetch_file(ws, req)))
    end
    for err in errors
        @test err isa SlackClaw.ChatError
        @test !occursin(token, err.detail)
        @test !occursin("https://", err.detail)
    end

    # Exercise the actual callback path and its bounded-discard cleanup on both versions.
    large_body = fill(0x61, 131073)
    gzip_body = UInt8[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff,
        0xeb, 0x0c, 0xf0, 0x73, 0x67, 0xf8, 0xdf, 0xc0, 0xc5, 0xeb, 0x04, 0x00,
        0x73, 0x3a, 0xa5, 0x31, 0x0a, 0x00, 0x00, 0x00]
    server = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        SlackClaw.HTTP.serve!(req -> begin
            headers = ["Content-Type" => "application/octet-stream"]
            req.target == "/gzip" && push!(headers, "Content-Encoding" => "gzip")
            body = req.target in ("/discard", "/large") ? large_body :
                req.target == "/empty" ? UInt8[] : req.target == "/gzip" ? gzip_body : bytes
            SlackClaw.HTTP.Response(req.target == "/discard" ? 302 : 200, headers, body)
        end, "127.0.0.1", 0; listenany=true, verbose=(SlackClaw.CHAT_HTTP_V2 ? false : -1))
    end
    try
        @test_logs min_level=Base.CoreLogging.Warn begin
            url = "http://127.0.0.1:$(SlackClaw.HTTP.port(server))"
            for _ in 1:2
                output = IOBuffer()
                selected = Ref(0)
                selector = function(status, headers)
                    selected[] += 1
                    @test status == 200
                    @test ("Content-Type" => "application/octet-stream") in headers
                    @test position(output) == 0
                    return output
                end
                result = SlackClaw.http_transport("GET", "$url/file", Pair{String,String}[]; response_stream=selector)
                @test selected[] == 1
                @test isempty(result.body)
                @test take!(output) == bytes
                result = SlackClaw.http_transport("GET", "$url/discard", Pair{String,String}[];
                    response_stream=(status, headers) -> nothing)
                @test result.status == 302
                @test isempty(result.body)
                for (target, expected) in (("large", large_body), ("empty", UInt8[]), ("gzip", gzip_body))
                    output = IOBuffer()
                    selected[] = 0
                    result = SlackClaw.http_transport("GET", "$url/$target", Pair{String,String}[];
                        response_stream=selector, timeout_s=20.5)
                    @test selected[] == 1
                    @test isempty(result.body)
                    @test take!(output) == expected
                end
            end
            sink = SlackClaw.ChatFileSink(IOBuffer(), length(bytes) - 1, 0, false)
            chat_test_error(() -> SlackClaw.http_transport("GET", "$url/file", Pair{String,String}[];
                response_stream=(status, headers) -> sink))
            @test sink.exceeded
            @test sink.bytes <= sink.max_bytes
        end
    finally
        close(server)
    end
end

@testset "chat_stream_abandons_unread_bodies" begin
    # Hold the end of each chunked response until after the client finishes.
    # Draining cleanup or even an EOF probe at the discard limit would hang.
    @test_logs min_level=Base.CoreLogging.Warn begin
        for mode in (:discard, :reject, :overflow)
            release = Channel{Nothing}(1)
            server = SlackClaw.HTTP.listen!("127.0.0.1", 0;
                listenany=true, verbose=(SlackClaw.CHAT_HTTP_V2 ? false : -1)) do http
                SlackClaw.HTTP.setstatus(http, mode == :discard ? 302 : 200)
                SlackClaw.HTTP.setheader(http, "Transfer-Encoding" => "chunked")
                SlackClaw.HTTP.startwrite(http)
                mode == :reject || write(http, fill(0x61, 65536))
                take!(release)
            end
            client = nothing
            try
                url = "http://127.0.0.1:$(SlackClaw.HTTP.port(server))/"
                selected = Ref(0)
                sink = SlackClaw.ChatFileSink(IOBuffer(), 1, 0, false)
                rejection = SlackClaw.ChatError(:forbidden, "Rejected response head")
                selector = function(status, headers)
                    selected[] += 1
                    @test status == (mode == :discard ? 302 : 200)
                    mode == :reject && throw(rejection)
                    return mode == :discard ? nothing : sink
                end
                client = @async try
                    SlackClaw.http_transport("GET", url, Pair{String,String}[];
                        response_stream=selector, timeout_s=30)
                catch e
                    e
                end
                @test timedwait(() -> istaskdone(client), 10) == :ok
                if istaskdone(client)
                    result = fetch(client)
                    @test selected[] == 1
                    if mode == :discard
                        @test result isa SlackClaw.ChatHTTPResponse
                        @test result.status == 302
                        @test isempty(result.body)
                    else
                        @test result isa Exception
                        @test sink.bytes == 0
                        @test mode == :overflow ? sink.exceeded : !sink.exceeded
                    end
                end
            finally
                put!(release, nothing)
                client === nothing || wait(client)
                close(server)
            end
        end
    end
end

@testset "chat_upload_streams_original_bytes" begin
    upload_file = SlackClaw.chat_upload_file
    response = SlackClaw.ChatHTTPResponse
    token = "fake-upload-bot-token-do-not-print"
    upload_url = "https://uploads.example.org/private/upload"
    bytes = UInt8[0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x80, 0x0a, 0x0d, 0x42]
    get_url = Dict("ok" => true, "file_id" => "FNEW", "upload_url" => upload_url)
    mktempdir() do dir
        path = joinpath(dir, "source.png")
        write(path, bytes)
        request(fields=Dict{String,Any}()) = merge(Dict{String,Any}("channel" => "C1", "thread_ts" => "1.0",
            "path" => path, "name" => "image\nname/with\\slashes.png", "comment" => "original bytes",
            "author" => FakeJSONObject("kind" => "row", "name" => "worker")), fields)
        for kind in ("person", "row"), category in ("public", "private"), has_comment in (false, true)
            input = Ref{Any}(nothing)
            completion = Dict("ok" => true, "files" => [FakeJSONObject("shares" => FakeJSONObject(
                category => FakeJSONObject("C1" => [FakeJSONObject("ts" => "2.000001")])))])
            fake, calls = chat_test_transport() do call
                if occursin("/files.getUploadURLExternal?", call["url"])
                    @test call["query"]["length"] == string(length(bytes))
                    @test call["query"]["filename"] == "image name_with_slashes.png"
                    return get_url
                elseif call["url"] == upload_url
                    @test call["method"] == "POST"
                    @test call["body"] isa IOStream
                    @test read(call["body"]) == bytes
                    @test ("Content-Length" => string(length(bytes))) in call["headers"]
                    @test ("Content-Type" => "application/octet-stream") in call["headers"]
                    @test !any(h -> lowercase(first(h)) == "authorization", call["headers"])
                    input[] = call["body"]
                    return response(200, Pair{String,String}[], UInt8[])
                end
                @test endswith(call["url"], "/files.completeUploadExternal")
                return completion
            end
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, posting_form=:custom, transport=fake)
            ws.bot_user_id, ws.bot_id = "UBOT", "BOWN"
            req = request(Dict("author" => FakeJSONObject("kind" => kind, "name" => "worker"),
                "comment" => has_comment ? "original bytes" : nothing))
            @test upload_file(ws, FakeJSONObject(pairs(req)...)) == Dict("file_id" => "FNEW", "ts" => "2.000001")
            @test length(calls) == 3
            @test !isopen(input[])
            body = calls[end]["body"]
            label = "$(kind == "row" ? "@worker" : "worker") ($kind via Ship of Tools)"
            @test body["files"] == [Dict("id" => "FNEW", "title" => "image name_with_slashes.png")]
            @test body["channel_id"] == "C1"
            @test body["thread_ts"] == "1.0"
            @test body["initial_comment"] == (has_comment ? "$label: original bytes" : label)
            @test ("Authorization" => "Bearer $token") in calls[end]["headers"]
            record = SlackClaw.normalize_message(ws, FakeJSONObject("ts" => "2.000001", "bot_id" => "BOWN",
                "subtype" => "file_share", "text" => body["initial_comment"]), "C1")
            @test record["origin"] == (kind == "row" ? "row" : "drawer")
            @test record["author"]["name"] == (kind == "row" ? "@worker" : "worker")
            @test record["text"] == (has_comment ? "original bytes" : "")
        end

        # Appending or replacing the path with a same-size sibling must refuse
        # completion, even while the original open descriptor is unchanged.
        for change in (:append, :replace)
            fake, calls = chat_test_transport() do call
                if call["url"] != upload_url
                    return get_url
                end
                @test read(call["body"]) == bytes
                if change == :append
                    open(path, "a") do changed
                        write(changed, "changed")
                    end
                else
                    sibling = joinpath(dir, "replacement.png")
                    write(sibling, reverse(bytes))
                    @test stat(sibling).inode != stat(path).inode
                    mv(sibling, path; force=true)
                    @test stat(path).size == length(bytes)
                    @test read(path) == reverse(bytes)
                end
                return response(200, Pair{String,String}[], UInt8[])
            end
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> upload_file(ws, request()))
            @test err isa SlackClaw.ChatError
            @test err.code == :io_error
            @test err.detail == "source changed during upload"
            @test err.outcome == :refused
            @test length(calls) == 2
            @test all(c -> !occursin("/files.completeUploadExternal", c["url"]), calls)
            @test !isopen(calls[end]["body"])
            write(path, bytes)
        end

        # Neither a refused byte upload nor an uncertain completion is resubmitted.
        timeout = chat_test_timeout()
        for (answers, code, outcome, expected_calls) in (
            (Any[timeout], :timeout, :refused, 1),
            (Any[get_url, timeout], :timeout, :refused, 2),
            (Any[get_url, response(503, Pair{String,String}[], UInt8[])], :unavailable, :refused, 2),
            (Any[get_url, response(200, Pair{String,String}[], UInt8[]), timeout], :timeout, :unknown, 3),
            (Any[get_url, response(200, Pair{String,String}[], UInt8[]), Dict("ok" => false, "error" => "missing_scope")], :forbidden, :refused, 3))
            fake, calls = chat_test_script(answers)
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> upload_file(ws, request()))
            @test err isa SlackClaw.ChatError
            @test err.code == code
            @test err.outcome == outcome
            @test length(calls) == expected_calls
            @test expected_calls == 3 ? endswith(calls[end]["url"], "/files.completeUploadExternal") :
                all(c -> !occursin("/files.completeUploadExternal", c["url"]), calls)
            @test !occursin(token, err.detail)
            @test !occursin(upload_url, err.detail)
            if expected_calls >= 2
                @test !isopen(calls[2]["body"])
            end
        end
        fake, calls = chat_test_script(Any[get_url, response(200, Pair{String,String}[], UInt8[]), Dict("ok" => true)])
        ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
        @test upload_file(ws, request(Dict("thread_ts" => nothing, "comment" => ""))) == Dict("file_id" => "FNEW")
        @test !haskey(calls[end]["body"], "thread_ts")
        @test calls[end]["body"]["initial_comment"] == "@worker (row via Ship of Tools): "

        for (fields, code) in ((Dict("path" => "relative"), :bad_request), (Dict("path" => dir), :bad_request),
                              (Dict("name" => " \n"), :bad_request), (Dict("name" => "é"^129), :bad_request),
                              (Dict("comment" => "é"^4097), :too_large), (Dict("comment" => 12), :bad_request),
                              (Dict("author" => FakeJSONObject("kind" => "bot", "name" => "worker")), :bad_request))
            fake, calls = chat_test_script(Any[])
            ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
            err = chat_test_error(() -> upload_file(ws, request(fields)))
            @test err.code == code
            @test err.outcome == :refused
            @test isempty(calls)
        end
        empty_path = joinpath(dir, "empty")
        write(empty_path, UInt8[])
        fake, calls = chat_test_script(Any[])
        ws = SlackClaw.ChatWorkspace(id="T1", bot_token=token, transport=fake)
        err = chat_test_error(() -> upload_file(ws, request(Dict("path" => empty_path))))
        @test err.code == :bad_request
        @test err.outcome == :refused
        @test isempty(calls)

        # The real transport must preserve an IO request body with either a
        # buffered response or a callback response, including its fixed length.
        upload_bytes = repeat(bytes, 16385)
        write(path, upload_bytes)
        received = Ref(UInt8[])
        @test_logs min_level=Base.CoreLogging.Warn begin
            server = SlackClaw.HTTP.serve!(req -> begin
                received[] = req.body
                @test SlackClaw.HTTP.header(req, "Content-Length", "") == string(length(upload_bytes))
                @test isempty(SlackClaw.HTTP.header(req, "Transfer-Encoding", ""))
                SlackClaw.HTTP.Response(200, "uploaded")
            end, "127.0.0.1", 0; listenany=true, verbose=(SlackClaw.CHAT_HTTP_V2 ? false : -1))
            try
                url = "http://127.0.0.1:$(SlackClaw.HTTP.port(server))/"
                for streamed in (false, true)
                    output = IOBuffer()
                    selected = Ref(0)
                    selector = function(status, headers)
                        selected[] += 1
                        @test status == 200
                        @test position(output) == 0
                        return output
                    end
                    open(path, "r") do input
                        result = SlackClaw.http_transport("POST", url,
                            ["Content-Length" => string(length(upload_bytes))]; body=input,
                            response_stream=streamed ? selector : nothing, timeout_s=20.5)
                        @test result.status == 200
                        @test isopen(input)
                        @test position(input) == length(upload_bytes)
                        @test selected[] == (streamed ? 1 : 0)
                        @test streamed ? isempty(result.body) : String(result.body) == "uploaded"
                    end
                    @test received[] == upload_bytes
                    @test String(take!(output)) == (streamed ? "uploaded" : "")
                end
            finally
                close(server)
            end
        end
    end
end
