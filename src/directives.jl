"""
Parse agent directives from Claude's response text.

Supported directives (at end of response):
- `[CONTINUE]` — immediately re-invoke with --resume
- `[CONTINUE: <prompt>]` — re-invoke with specific follow-up prompt
- `[SCHEDULE: <duration>: <prompt>]` — schedule a follow-up (e.g. "1h", "30m", "2h30m")
- No directive = task complete
"""

struct Directive
    type::Symbol     # :continue, :schedule, :done
    prompt::String   # follow-up prompt (for continue/schedule)
    delay_s::Int     # seconds until execution (for schedule)
end

const DIRECTIVE_DONE = Directive(:done, "", 0)

"""
    parse_directives(text::String) -> (Directive, String)

Extract directive from response text. Returns the directive and cleaned text.
"""
function parse_directives(text::String)
    # Match [CONTINUE] or [CONTINUE: prompt]
    m = match(r"\[CONTINUE(?::\s*(.+?))?\]\s*$"s, text)
    if m !== nothing
        prompt = m.captures[1] === nothing ? "continue" : strip(String(m.captures[1]))
        clean = strip(text[1:m.offset-1])
        return Directive(:continue, prompt, 0), clean
    end

    # Match [SCHEDULE: duration: prompt]
    m = match(r"\[SCHEDULE:\s*(\d+[hm]\w*)\s*:\s*(.+?)\]\s*$"s, text)
    if m !== nothing
        delay = parse_duration(String(m.captures[1]))
        prompt = strip(String(m.captures[2]))
        clean = strip(text[1:m.offset-1])
        return Directive(:schedule, prompt, delay), clean
    end

    return DIRECTIVE_DONE, text
end

"""
    parse_duration(s::String) -> Int

Parse duration string like "1h", "30m", "1h30m" into seconds.
"""
function parse_duration(s::String)
    total = 0
    for m in eachmatch(r"(\d+)([hm])", s)
        val = parse(Int, m.captures[1])
        unit = m.captures[2]
        total += unit == "h" ? val * 3600 : val * 60
    end
    return total > 0 ? total : 3600  # default 1h if unparseable
end

const DIRECTIVE_INSTRUCTIONS = """
You have access to agent directives that control your execution flow. \
Place ONE directive at the very end of your response when needed:

- [CONTINUE] — You have more work to do right now. You'll be re-invoked immediately with your session resumed.
- [CONTINUE: <specific next step>] — Same, but with a specific prompt for your next invocation.
- [SCHEDULE: <duration>: <what to do>] — Schedule a follow-up. Duration: "30m", "1h", "2h30m". Use this when waiting for a long process to finish.

If your task is complete, don't include any directive.

Examples:
- "I've started the analysis pipeline. It should take about 2 hours. [SCHEDULE: 2h: Check if the analysis pipeline completed and report results]"
- "I've processed 3 of 10 datasets. Moving to the next batch. [CONTINUE]"
- "Here are your results: ... (no directive needed, task is done)"
"""
