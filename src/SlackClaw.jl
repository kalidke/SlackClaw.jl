module SlackClaw

using HTTP
using JSON

include("config.jl")
include("message_types.jl")
include("slack_api.jl")
include("claude_runner.jl")
include("monitor.jl")

export SlackClawConfig,
       start_monitor,
       run_monitor,
       stop_monitor!,
       SlackMessage,
       ClaudeResult,
       MonitorState

end # module SlackClaw
