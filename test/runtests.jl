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

@testset "SlackClawConfig defaults" begin
    cfg = SlackClawConfig(slack_bot_token="fake", slack_channel_id="C0")
    @test cfg.poll_interval_s == 10
    @test cfg.max_concurrent_tasks == 5
    @test cfg.max_active_threads == 10
    @test cfg.max_continue == 10
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
