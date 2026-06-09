using SlackClaw
using Documenter

DocMeta.setdocmeta!(SlackClaw, :DocTestSetup, :(using SlackClaw); recursive=true)

makedocs(;
    modules=[SlackClaw],
    authors="klidke@unm.edu",
    sitename="SlackClaw.jl",
    format=Documenter.HTML(;
        canonical="https://LidkeLab.github.io/SlackClaw.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Slack App Setup" => "setup.md",
        "Socket Mode" => "socket-mode.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/LidkeLab/SlackClaw.jl",
    devbranch="main",
)
