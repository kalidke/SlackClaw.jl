module SlackClaw

using Dates
using HTTP
using JSON

include("config.jl")
include("directives.jl")
include("message_types.jl")
include("slack_api.jl")
include("claude_runner.jl")
include("monitor.jl")
include("socket_mode.jl")
include("setup.jl")

export SlackClawConfig,
       start_monitor,
       run_monitor,
       run_socket_fleet,
       stop_monitor!,
       SlackMessage,
       ClaudeResult,
       MonitorState

"""
    SlackClaw.api() -> String

Return this package's `api_overview.md` — an LLM-parseable API reference.
Unexported; call as `SlackClaw.api()`. `println(SlackClaw.api())` prints it.
"""
function api()
    path = joinpath(@__DIR__, "..", "api_overview.md")
    isfile(path) ? read(path, String) : "SlackClaw: api_overview.md not found at $path"
end

end # module SlackClaw
