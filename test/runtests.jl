using SlackClaw
using Test

@testset "SlackClaw.jl" begin

@testset "parse_duration" begin
    pd = SlackClaw.parse_duration
    @test pd("1h") == 3600
    @test pd("30m") == 1800
    @test pd("1h30m") == 5400
    @test pd("2h") == 7200
    @test pd("2h30m") == 9000
    @test pd("garbage") == 3600  # default fallback
    @test pd("0m") == 3600      # zero parses but total=0 → default
end

@testset "parse_directives" begin
    pd = SlackClaw.parse_directives

    # No directive → done
    dir, clean = pd("Here are your results.")
    @test dir.type == :done
    @test clean == "Here are your results."

    # [CONTINUE] bare
    dir, clean = pd("Did step 1.\n[CONTINUE]")
    @test dir.type == :continue
    @test dir.prompt == "continue"
    @test clean == "Did step 1."

    # [CONTINUE] with trailing whitespace
    dir, clean = pd("Done so far. [CONTINUE]  \n")
    @test dir.type == :continue

    # [CONTINUE: prompt]
    dir, clean = pd("Processed batch 1.\n[CONTINUE: process batch 2]")
    @test dir.type == :continue
    @test dir.prompt == "process batch 2"
    @test clean == "Processed batch 1."

    # [SCHEDULE: duration: prompt]
    dir, clean = pd("Pipeline started.\n[SCHEDULE: 2h: check results]")
    @test dir.type == :schedule
    @test dir.delay_s == 7200
    @test dir.prompt == "check results"
    @test clean == "Pipeline started."

    # [SCHEDULE] with mixed duration
    dir, _ = pd("ok\n[SCHEDULE: 1h30m: follow up]")
    @test dir.type == :schedule
    @test dir.delay_s == 5400

    # Directive-like text in middle is NOT matched (regex anchored to end)
    dir, clean = pd("[CONTINUE] but then more text after")
    @test dir.type == :done
    @test clean == "[CONTINUE] but then more text after"

    # Empty text
    dir, clean = pd("")
    @test dir.type == :done
    @test clean == ""
end

@testset "parse_slack_messages" begin
    psm = SlackClaw.parse_slack_messages

    # Normal message
    msgs = psm([Dict("ts" => "1234.0", "user" => "U1", "text" => "hello", "thread_ts" => "")])
    @test length(msgs) == 1
    @test msgs[1].ts == "1234.0"
    @test msgs[1].user == "U1"
    @test msgs[1].text == "hello"

    # Missing ts → skipped
    msgs = psm([Dict("user" => "U1", "text" => "no ts")])
    @test isempty(msgs)

    # Missing optional fields default to ""
    msgs = psm([Dict("ts" => "1.0")])
    @test length(msgs) == 1
    @test msgs[1].user == ""
    @test msgs[1].text == ""
    @test msgs[1].thread_ts == ""

    # Multiple messages
    msgs = psm([
        Dict("ts" => "1.0", "user" => "U1", "text" => "a"),
        Dict("ts" => "2.0", "user" => "U2", "text" => "b"),
    ])
    @test length(msgs) == 2

    # Empty input
    msgs = psm(Dict[])
    @test isempty(msgs)
end

@testset "should_process" begin
    sp = SlackClaw.should_process
    # Need a config with a known bot_user_id
    cfg = SlackClawConfig(
        slack_bot_token="fake",
        slack_channel_id="C0",
        bot_user_id="UBOT",
    )

    normal_msg = SlackMessage("1.0", "UHUMAN", "hello", "")

    # Normal message → true
    @test sp(normal_msg, cfg, Dict()) == true

    # Has bot_id → false
    @test sp(normal_msg, cfg, Dict("bot_id" => "B1")) == false

    # Bot subtype → false
    @test sp(normal_msg, cfg, Dict("subtype" => "bot_message")) == false

    # Own bot user → false
    own_msg = SlackMessage("1.0", "UBOT", "self-talk", "")
    @test sp(own_msg, cfg, Dict()) == false

    # Empty text → false
    empty_msg = SlackMessage("1.0", "UHUMAN", "  ", "")
    @test sp(empty_msg, cfg, Dict()) == false
end

@testset "parse_claude_output" begin
    pco = SlackClaw.parse_claude_output

    # Valid JSON success
    json = """{"result":"hello world","is_error":false,"total_cost_usd":0.05,"session_id":"sess123","duration_ms":500}"""
    r = pco(json, 1000)
    @test r.success == true
    @test r.result_text == "hello world"
    @test r.cost_usd == 0.05
    @test r.session_id == "sess123"
    @test r.duration_ms == 500  # uses CLI duration when available

    # Valid JSON error
    json = """{"result":"something broke","is_error":true,"total_cost_usd":0.01,"session_id":"","duration_ms":100}"""
    r = pco(json, 1000)
    @test r.success == false
    @test r.result_text == "something broke"

    # Invalid JSON → raw text fallback
    r = pco("raw output text", 2000)
    @test r.success == true
    @test r.result_text == "raw output text"
    @test r.duration_ms == 2000
    @test r.cost_usd == 0.0
    @test r.session_id == ""

    # Error prefix in raw text → not success
    r = pco("Error: something failed", 100)
    @test r.success == false

    # Minimal valid JSON (missing optional fields)
    json = """{"result":"ok"}"""
    r = pco(json, 300)
    @test r.success == true
    @test r.result_text == "ok"
    @test r.cost_usd == 0.0
    @test r.session_id == ""
end

@testset "chunk_text" begin
    ct = SlackClaw.chunk_text

    # Short text passes through untouched
    @test ct("hello", 100) == ["hello"]
    # Exactly at limit → single chunk
    @test ct("a"^100, 100) == ["a"^100]
    # Empty / whitespace-only → no chunks
    @test isempty(ct("", 100))
    @test isempty(ct("   \n  ", 100))

    # Over limit, no newlines → hard split, nothing lost
    chunks = ct("a"^250, 100)
    @test length(chunks) == 3
    @test all(length.(chunks) .<= 100)
    @test join(chunks) == "a"^250

    # Prefers a newline boundary in the latter half of the window
    text = "A"^40 * "\n" * "B"^40
    chunks = ct(text, 60)
    @test chunks == ["A"^40, "B"^40]

    # Early newline (first half) is ignored in favor of a full window
    text = "ab\n" * "c"^120
    chunks = ct(text, 100)
    @test length(chunks) == 2
    @test length(chunks[1]) == 100

    # Multi-line content reassembles (modulo the consumed newlines)
    text = join(["line $i is some text" for i in 1:40], "\n")
    chunks = ct(text, 120)
    @test all(length.(chunks) .<= 120)
    @test replace(join(chunks, "\n"), "\n" => "") == replace(text, "\n" => "")
end

@testset "classify_socket_event" begin
    cse = SlackClaw.classify_socket_event
    cfg = SlackClawConfig(
        slack_bot_token="fake", slack_channel_id="C0", bot_user_id="UBOT",
        listen_channel_ids=["CLISTEN"],
    )
    tracked = Set(["111.000"])
    base = Dict("type" => "message", "channel" => "C0", "user" => "U1",
                "text" => "hi", "ts" => "200.0")

    # Top-level message in primary channel
    route, msg = cse(copy(base), cfg, tracked)
    @test route == :primary
    @test msg.ts == "200.0"
    @test msg.text == "hi"

    # Non-message event types ignored
    @test cse(Dict("type" => "reaction_added"), cfg, tracked)[1] == :ignore

    # Edits/deletes/joins ignored (different payload shapes)
    for st in ("message_changed", "message_deleted", "channel_join")
        d = copy(base); d["subtype"] = st
        @test cse(d, cfg, tracked)[1] == :ignore
    end

    # thread_broadcast subtype is dispatchable
    d = copy(base); d["subtype"] = "thread_broadcast"
    @test cse(d, cfg, tracked)[1] == :primary

    # Reply in a tracked thread
    d = copy(base); d["thread_ts"] = "111.000"
    route, msg = cse(d, cfg, tracked)
    @test route == :thread_reply
    @test msg.thread_ts == "111.000"

    # Reply in an untracked thread ignored
    d = copy(base); d["thread_ts"] = "999.0"
    @test cse(d, cfg, tracked)[1] == :ignore

    # Thread parent (thread_ts == ts) is a top-level message
    d = copy(base); d["thread_ts"] = "200.0"
    @test cse(d, cfg, tracked)[1] == :primary

    # Listen channel top-level message
    d = copy(base); d["channel"] = "CLISTEN"
    @test cse(d, cfg, tracked)[1] == :listen

    # Unconfigured channel ignored
    d = copy(base); d["channel"] = "CX"
    @test cse(d, cfg, tracked)[1] == :ignore

    # Missing ts ignored
    @test cse(Dict("type" => "message", "channel" => "C0"), cfg, tracked)[1] == :ignore

    # Bot messages still classified — should_process filters at dispatch,
    # after the cursor claim (cursors advance past bot messages too)
    d = copy(base); d["bot_id"] = "B1"
    @test cse(d, cfg, tracked)[1] == :primary
end

@testset "cursor claims" begin
    cfg = SlackClawConfig(slack_bot_token="fake", slack_channel_id="C0")
    state = SlackClaw.MonitorState(
        cfg, "100.0", true, Task[], nothing,
        Dict{String,SlackClaw.ThreadSession}(), Dict{String,Float64}(),
        SlackClaw.ScheduledTask[], Dict{String,String}("CL" => "100.0"),
        Dict{String,String}(), 0.0, ReentrantLock())

    # Primary cursor: first claim wins, replays and older ts rejected
    @test SlackClaw.claim_primary!(state, "200.0")
    @test !SlackClaw.claim_primary!(state, "200.0")
    @test !SlackClaw.claim_primary!(state, "150.0")
    @test state.last_ts == "200.0"

    # Thread reply cursor
    sess = SlackClaw.ThreadSession("111.0", "sid", "111.0", 0.0, "C0")
    @test SlackClaw.claim_thread_reply!(state, sess, "112.0")
    @test !SlackClaw.claim_thread_reply!(state, sess, "112.0")
    @test sess.last_reply_ts == "112.0"

    # Listen channel cursor
    @test SlackClaw.claim_listen!(state, "CL", "101.0")
    @test !SlackClaw.claim_listen!(state, "CL", "101.0")
    @test state.listen_last_ts["CL"] == "101.0"
end

@testset "thread expiry" begin
    tla = SlackClaw.thread_last_active
    iet = SlackClaw.idle_expired_threads
    now = time()

    # last_active = newest of created / last_reply_ts
    s_idle = SlackClaw.ThreadSession("1.0", "sid", string(now - 8 * 86400), now - 60 * 86400, "C0")
    @test isapprox(tla(s_idle), now - 8 * 86400; atol=1.0)

    # Unparseable last_reply_ts falls back to created
    s_hour = SlackClaw.ThreadSession("2.0", "sid", "", now - 3600, "C0")
    @test tla(s_hour) == now - 3600

    # Reply ts older than created → created wins
    s_fresh = SlackClaw.ThreadSession("3.0", "sid", string(now - 86400), now - 60, "C0")
    @test tla(s_fresh) == now - 60

    threads = Dict("1.0" => s_idle, "2.0" => s_hour, "3.0" => s_fresh)

    # 7d cutoff: only the 8d-idle thread expires
    expired = iet(threads, 7 * 86400, now)
    @test length(expired) == 1
    @test expired[1].thread_ts == "1.0"

    # Cutoff 0 disables idle expiry entirely
    @test isempty(iet(threads, 0, now))

    # 30m cutoff catches the 8d and 1h threads, keeps the 60s one
    @test length(iet(threads, 1800, now)) == 2
end

@testset "SlackClawConfig defaults" begin
    cfg = SlackClawConfig(slack_bot_token="fake", slack_channel_id="C0")
    @test cfg.poll_interval_s == 10
    @test cfg.max_concurrent_tasks == 5
    @test cfg.max_active_threads == 3
    @test cfg.max_thread_idle_s == 604800
    @test cfg.max_continue == 10
    @test cfg.socket_mode == false
    @test cfg.reconcile_interval_s == 300
    @test cfg.agent_directives == true
    @test cfg.claude_timeout_s == 3600
    @test cfg.max_turns == 30
    @test isempty(cfg.allowed_tools)
    @test isempty(cfg.listen_channel_ids)
    @test cfg.max_budget_usd == 0.0
    @test cfg.model == ""
    @test cfg.bot_user_id == ""
    @test cfg.proactive_enabled == false
    @test cfg.proactive_prompt == ""
    @test cfg.proactive_interval_s == 3600
end

end
