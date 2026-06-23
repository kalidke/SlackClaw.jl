"""
SlackClaw setup assistant.

Automates everything that can be automated and groups the human-only Slack
steps into a single browser session, so setup is:

    generate manifest  →  (human: create app, install, copy two tokens)  →  verify & wire

The human only does what no API can: create the app from the manifest,
authorize the OAuth install, and mint the app-level token. Everything else —
validating tokens, resolving the channel, joining public channels, the live
socket self-test, writing the env file — is automated. See [`setup`](@ref).
"""

# Bot scopes the running monitor actually uses, plus channels:join for setup
# auto-join. Kept in sync with the Slack API calls in slack_api.jl.
const SETUP_BOT_SCOPES = [
    "channels:history",   # read public-channel history (conversations.history/replies)
    "channels:read",      # resolve public channel info/list
    "channels:join",      # auto-join public channels during setup
    "groups:history",     # read private-channel history
    "groups:read",        # resolve private channel info/list
    "im:history",         # read DMs (message.im events)
    "chat:write",         # post replies
    "reactions:write",    # eyes / check-mark reactions
    "files:write",        # upload files to threads
]

# Bot events Slack pushes over the socket.
const SETUP_BOT_EVENTS = ["message.channels", "message.groups", "message.im"]

const SETUP_APPS_URL = "https://api.slack.com/apps"

# --- Manifest generation ---

"""
    generate_manifest(; app_name="SlackClaw", description=...) -> String

Build a Slack app manifest (YAML) that pre-configures everything SlackClaw
needs in one shot: bot scopes, message event subscriptions, and Socket Mode
enabled. Paste it into $(SETUP_APPS_URL) → Create New App → From an app
manifest, so the human never has to toggle scopes or events by hand.
"""
function generate_manifest(; app_name::AbstractString="SlackClaw",
                           description::AbstractString="Bridges this Slack channel to Claude Code.")
    lines = String[
        "display_information:",
        "  name: $app_name",
        "  description: $description",
        "features:",
        "  bot_user:",
        "    display_name: $app_name",
        "    always_online: true",
        "oauth_config:",
        "  scopes:",
        "    bot:",
    ]
    for s in SETUP_BOT_SCOPES
        push!(lines, "      - $s")
    end
    append!(lines, [
        "settings:",
        "  event_subscriptions:",
        "    bot_events:",
    ])
    for e in SETUP_BOT_EVENTS
        push!(lines, "      - $e")
    end
    append!(lines, [
        "  interactivity:",
        "    is_enabled: false",
        "  org_deploy_enabled: false",
        "  socket_mode_enabled: true",
        "  token_rotation_enabled: false",
    ])
    return join(lines, "\n") * "\n"
end

"""
    print_setup_instructions([io]; app_name="SlackClaw", manifest_path="")

Print the manifest and the grouped human-only browser steps. Every step here is
done in one sitting at https://api.slack.com/apps — there is no back-and-forth.
"""
function print_setup_instructions(io::IO=stdout; app_name::AbstractString="SlackClaw",
                                  manifest_path::AbstractString="")
    bar = "="^72
    println(io, bar)
    println(io, "SlackClaw setup — do ALL of the following once, in your browser:")
    println(io, bar)
    println(io)
    println(io, "1. Open $SETUP_APPS_URL  →  Create New App  →  From an app manifest.")
    println(io, "   Pick your workspace, then paste this manifest and click Create:")
    println(io)
    for l in split(rstrip(generate_manifest(; app_name), '\n'), '\n')
        println(io, "       ", l)
    end
    isempty(manifest_path) || println(io, "   (also saved to $manifest_path)")
    println(io)
    println(io, "2. Install App  →  Install to Workspace  →  Allow.")
    println(io, "   Copy the Bot User OAuth Token (starts with xoxb-).")
    println(io)
    println(io, "3. Basic Information  →  App-Level Tokens  →  Generate Token and Scopes")
    println(io, "   →  add scope connections:write  →  Generate.")
    println(io, "   Copy the App-Level Token (starts with xapp-).")
    println(io)
    println(io, "4. ONLY if the channel you want to monitor is PRIVATE, invite the bot in it:")
    println(io, "       /invite @$app_name")
    println(io, "   (Public channels are joined automatically — skip this.)")
    println(io)
    println(io, "Then come back here with: the xoxb- token, the xapp- token, and the")
    println(io, "channel name or ID. Everything after that is automated.")
    println(io, bar)
    return nothing
end

# --- Automated verification & wiring ---

"""
    socket_selftest(config; timeout_s=15) -> Bool

Open a Socket Mode connection and wait for Slack's `hello` frame, then close.
Confirms the app token + `connections:write` end to end. Returns `true` if the
`hello` arrives before the timeout. `apps.connections.open` failures (bad app
token) propagate to the caller.
"""
function socket_selftest(config::SlackClawConfig; timeout_s::Real=15)
    url = slack_apps_connections_open(config)
    got_hello = Ref(false)
    t = @async try
        HTTP.WebSockets.open(url) do ws
            for raw in ws
                data = try JSON.parse(String(raw)) catch; nothing end
                if data isa Dict && get(data, "type", "") == "hello"
                    got_hello[] = true
                    break
                end
            end
        end
    catch
    end
    for _ in 1:round(Int, timeout_s * 10)
        (got_hello[] || istaskdone(t)) && break
        sleep(0.1)
    end
    return got_hello[]
end

"""
Resolve a channel name (`dev`, `#dev`) or ID (`C0123…`) to `(id, info_dict)`.
Tries an ID lookup first (authoritative), then falls back to a name search over
the channels the bot can see.
"""
function resolve_channel(config::SlackClawConfig, channel::AbstractString)
    ch = String(strip(channel))
    name = String(lstrip(ch, '#'))
    if !startswith(ch, "#")                 # might be an ID — cheapest authoritative check
        try
            info = slack_conversations_info(config, ch)
            return get(info, "id", ch), info
        catch
        end
    end
    for c in slack_conversations_list(config)
        get(c, "name", "") == name && return c["id"], c
    end
    error("channel \"$channel\" not found. If it is private, /invite the bot to it " *
          "first; if public, check the name. (Searched all channels the bot can see.)")
end

function write_env_file(path::AbstractString, bot, app, channel_id)
    open(path, "w") do io
        println(io, "# SlackClaw credentials — secret, do not commit.")
        println(io, "export SLACK_BOT_TOKEN=\"$bot\"")
        println(io, "export SLACK_APP_TOKEN=\"$app\"")
        println(io, "export SLACK_CHANNEL_ID=\"$channel_id\"")
    end
    try chmod(path, 0o600) catch; end
    return path
end

function ensure_gitignored(repo_dir::AbstractString, entry::AbstractString)
    gi = joinpath(repo_dir, ".gitignore")
    if isfile(gi)
        entry in strip.(readlines(gi)) && return
        open(gi, "a") do io; println(io, entry); end
    else
        open(gi, "w") do io; println(io, entry); end
    end
    return nothing
end

function print_report(checks::Vector; io::IO=stdout, env_path::AbstractString="")
    println(io)
    println(io, "SlackClaw setup report")
    println(io, "-"^60)
    for (label, ok, detail) in checks
        mark = ok ? "[ OK ]" : "[FAIL]"
        line = "  $mark  $label"
        isempty(detail) || (line *= "  — $detail")
        println(io, line)
    end
    println(io, "-"^60)
    if all(c -> c[2], checks)
        println(io, "All checks passed. Start the monitor with:")
        isempty(env_path) || println(io, "    source $(env_path)")
        println(io, "    julia --project -e 'using SlackClaw; run_monitor(SlackClawConfig())'")
    else
        println(io, "Some checks failed — fix the above and re-run SlackClaw.verify_setup(...).")
    end
    return nothing
end

"""
    verify_setup(; bot_token, app_token, channel, repo_dir=pwd(),
                 write_env=true, env_path=joinpath(repo_dir, "slackclaw.env"),
                 announce=true) -> NamedTuple

The automated half of setup. Given the two tokens and a channel name/ID, this:
validates the bot token (`auth.test`), resolves the channel, auto-joins it when
public, runs a live Socket Mode self-test with the app token, writes a
gitignored `slackclaw.env`, and posts a confirmation to the channel. Prints a
pass/fail checklist and returns `(; ok, channel_id, bot_user_id, team, checks)`.
Re-runnable and side-effect-light (the only channel post is the confirmation).
"""
function verify_setup(; bot_token::AbstractString, app_token::AbstractString,
                      channel::AbstractString, repo_dir::AbstractString=pwd(),
                      write_env::Bool=true,
                      env_path::AbstractString=joinpath(repo_dir, "slackclaw.env"),
                      announce::Bool=true)
    bot = String(strip(bot_token))
    app = String(strip(app_token))
    checks = Tuple{String,Bool,String}[]
    add!(label, ok, detail="") = push!(checks, (label, ok, detail))

    (startswith(bot, "xapp") || startswith(app, "xoxb")) &&
        @warn "SlackClaw.verify_setup: tokens look swapped — bot should be xoxb-, app should be xapp-"

    cfg = SlackClawConfig(slack_bot_token=bot, app_token=app,
                          slack_channel_id="", repo_dir=repo_dir)

    # 1. Bot token
    bot_uid = ""; team = ""
    try
        info = slack_auth_test_info(cfg)
        bot_uid = get(info, "user_id", "")
        team = get(info, "team", "")
        add!("Bot token valid", true, "team=$(team), bot=@$(get(info, "user", "?"))")
    catch e
        add!("Bot token valid", false, sprint(showerror, e))
        print_report(checks)
        return (; ok=false, channel_id="", bot_user_id=bot_uid, team, checks)
    end

    # 2. Resolve channel
    channel_id = ""; ch_name = ""; is_private = false; is_member = false
    try
        cinfo = Dict()
        channel_id, cinfo = resolve_channel(cfg, channel)
        ch_name = get(cinfo, "name", channel_id)
        is_private = get(cinfo, "is_private", false)
        is_member = get(cinfo, "is_member", false)
        cfg.slack_channel_id = channel_id
        add!("Channel resolved", true,
             "#$(ch_name) ($(channel_id))$(is_private ? ", private" : "")")
    catch e
        add!("Channel resolved", false, sprint(showerror, e))
        print_report(checks)
        return (; ok=false, channel_id="", bot_user_id=bot_uid, team, checks)
    end

    # 3. Membership / auto-join
    if is_member
        add!("Bot in channel", true)
    elseif !is_private
        try
            slack_conversations_join(cfg, channel_id)
            is_member = true
            add!("Bot joined channel", true, "auto-joined #$(ch_name)")
        catch e
            add!("Bot joined channel", false, sprint(showerror, e))
        end
    else
        add!("Bot in channel", false, "private channel — run  /invite @bot  in #$(ch_name), then re-run")
    end

    # 4. App token + live socket
    try
        ok = socket_selftest(cfg)
        add!("Socket Mode live (app token)", ok, ok ? "hello received" : "no hello before timeout")
    catch e
        add!("Socket Mode live (app token)", false, sprint(showerror, e))
    end

    # 5. Write env file
    if write_env
        try
            write_env_file(env_path, bot, app, channel_id)
            ensure_gitignored(repo_dir, basename(env_path))
            add!("Wrote env file", true, "$(env_path) (chmod 600, gitignored)")
        catch e
            add!("Wrote env file", false, sprint(showerror, e))
        end
    end

    # 6. Confirmation post (only if the bot is actually in the channel)
    if announce && is_member
        try
            slack_post_message(cfg, ":white_check_mark: SlackClaw is set up — now monitoring this channel.")
            add!("Posted confirmation to channel", true)
        catch e
            add!("Posted confirmation to channel", false, sprint(showerror, e))
        end
    end

    print_report(checks; env_path=(write_env ? env_path : ""))
    return (; ok=all(c -> c[2], checks), channel_id, bot_user_id=bot_uid, team, checks)
end

# --- Interactive wrapper ---

_prompt(msg) = (print(msg); String(strip(readline())))

"""
    setup(; repo_dir=pwd(), app_name="SlackClaw", write_env=true)

Interactive setup wizard. Writes the manifest to `slackclaw_manifest.yaml`,
prints it with the grouped browser steps, waits while you do them, then prompts
for the two tokens and the channel and runs [`verify_setup`](@ref). For
scripted / non-interactive use, call [`generate_manifest`](@ref) and
[`verify_setup`](@ref) directly.
"""
function setup(; repo_dir::AbstractString=pwd(), app_name::AbstractString="SlackClaw",
               write_env::Bool=true)
    manifest_path = joinpath(repo_dir, "slackclaw_manifest.yaml")
    try
        write(manifest_path, generate_manifest(; app_name))
    catch
        manifest_path = ""
    end
    print_setup_instructions(; app_name, manifest_path)
    print("\nPress Enter once the app is created and you have BOTH tokens... ")
    readline()
    bot = _prompt("Bot User OAuth Token (xoxb-): ")
    app = _prompt("App-Level Token      (xapp-): ")
    channel = _prompt("Channel to monitor (e.g. #dev or C0123ABCD): ")
    return verify_setup(; bot_token=bot, app_token=app, channel, repo_dir, write_env)
end
