using SlackClaw
using Documenter

DocMeta.setdocmeta!(SlackClaw, :DocTestSetup, :(using SlackClaw); recursive=true)

makedocs(;
    modules=[SlackClaw],
    authors="klidke@unm.edu",
    sitename="SlackClaw.jl",
    format=Documenter.HTML(;
        canonical="https://kalidke.github.io/SlackClaw.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Slack App Setup" => "setup.md",
        "Use Cases" => "use-cases.md",
        "Features" => "features.md",
        "Socket Mode" => "socket-mode.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/kalidke/SlackClaw.jl",
    devbranch="main",
)
