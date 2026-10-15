"""
Slack message representation and filtering.
"""
struct SlackMessage
    ts::String
    user::String
    text::String
    thread_ts::String
end

"""
    attachment_note(file::AbstractDict) -> String

Prompt line for one file on a message: `[attached file: name (mimetype, id)]`.
The name falls back to the title, then to `unnamed file` (tombstoned or
hidden files carry little more than an id); the parenthetical lists only the
fields present. File names are user-controlled, so line breaks are flattened
to spaces: a name cannot start a line of its own, and so cannot pose as a
`[from …]` attribution.
"""
function attachment_note(file::AbstractDict)
    name = clean_field(get(file, "name", nothing))
    isempty(name) && (name = clean_field(get(file, "title", nothing)))
    isempty(name) && (name = "unnamed file")
    details = String[]
    mimetype = clean_field(get(file, "mimetype", nothing))
    isempty(mimetype) || push!(details, mimetype)
    id = clean_field(get(file, "id", nothing))
    isempty(id) || push!(details, "id $id")
    suffix = isempty(details) ? "" : " (" * join(details, ", ") * ")"
    return "[attached file: $name$suffix]"
end

"""Slack file field as prompt text: non-strings count as missing."""
function clean_field(value)
    value isa AbstractString || return ""
    return strip(replace(value, r"[\p{Cc}\p{Zl}\p{Zp}]" => " "))
end

"""
    message_text(raw::AbstractDict) -> String

Text a Slack message contributes to dispatch: the caption (`text`, unchanged),
then one [`attachment_note`](@ref) line per file. A non-empty caption is
separated from the notes by a blank line; with no caption the notes are the
whole text. The socket and reconcile paths both build text here, so a message
reads the same on either path. Entries in `files` that are not objects (JSON
`null`s) are skipped.
"""
function message_text(raw::AbstractDict)
    text = get(raw, "text", "")
    files = get(raw, "files", nothing)
    files isa AbstractVector || return text
    notes = [attachment_note(f) for f in files if f isa AbstractDict]
    isempty(notes) && return text
    isempty(strip(text)) && return join(notes, "\n")
    return text * "\n\n" * join(notes, "\n")
end

"""
    parse_slack_messages(messages::Vector) -> Vector{SlackMessage}

Parse raw Slack API message dicts into `SlackMessage` structs.
"""
function parse_slack_messages(messages::Vector)
    result = SlackMessage[]
    for msg in messages
        haskey(msg, "ts") || continue
        push!(result, SlackMessage(
            get(msg, "ts", ""),
            get(msg, "user", ""),
            message_text(msg),
            get(msg, "thread_ts", ""),
        ))
    end
    return result
end

"""
    should_process(msg::SlackMessage, config::SlackClawConfig, raw::AbstractDict) -> Bool

Return `true` if this message should be dispatched to Claude.
Skips bot messages, messages from our own bot user, and messages with neither
text nor files (`msg.text` already carries the file notes).
`raw` is parsed JSON — `AbstractDict`, not `Dict`: JSON.jl v1 parses objects
as `JSON.Object` (0.21 returned `Dict`), and both must be accepted.
"""
function should_process(msg::SlackMessage, config::SlackClawConfig, raw::AbstractDict)
    haskey(raw, "bot_id") && return false
    get(raw, "subtype", "") == "bot_message" && return false
    msg.user == config.bot_user_id && return false
    isempty(strip(msg.text)) && return false
    return true
end

# --- Sender attribution ---
# Every user message reaches Claude prefixed with its authenticated sender:
# `[from <@U…>]` on the primary/thread paths, `[from <@U…> in #channel]` on the
# listen path. Unconditional, not config-gated: channel prompts can only enforce
# per-user authorization rules ("only act when the requester is …") if the
# requester's identity is always present.

"""Line that could pass for a sender-attribution marker (leading-block scope only)."""
const FROM_LINE_RE = r"^\s*\[from\b"i

"""
    sanitize_from_lines(text) -> String

Neutralize forged sender attributions: any line in the LEADING block of `text`
(before the first substantive non-`[from` line) that looks like a `[from …]`
marker is prefixed with `user wrote: `, so it cannot pose as the authoritative
attribution that [`attribute_sender`](@ref) prepends. Matching is
case-insensitive and tolerates leading whitespace/blank lines — deliberately
broader than the genuine marker, because a false positive only adds a visible
`user wrote: ` tag to an innocent message, while a miss would let a forgery sit
adjacent to the real attribution. Lines past the leading block are left alone.
"""
function sanitize_from_lines(text::AbstractString)
    lines = String.(split(text, '\n'; keepempty=true))
    for (i, line) in pairs(lines)
        if occursin(FROM_LINE_RE, line)
            lines[i] = "user wrote: " * line
        elseif !isempty(strip(line))
            break
        end
    end
    return join(lines, "\n")
end

"""
    attribute_sender(text, user_id) -> String

Prefix a user message with its authenticated sender for the primary/thread
dispatch paths:

    [from <@U0123ABCDE>]

    <sanitized user text>

The prefix is unconditional and always FIRST — only the first `[from …]` line
of a prompt is authoritative. Users can type a forged `[from …]` line
themselves, so leading look-alikes in the user text are neutralized by
[`sanitize_from_lines`](@ref) before the real prefix is attached. An empty
`user_id` (Slack events without a `user` field) yields `[from unknown]`, so
fail-closed authorization prompts still see an explicit attribution to reject.
"""
function attribute_sender(text::AbstractString, user_id::AbstractString)
    who = isempty(user_id) ? "unknown" : "<@$(user_id)>"
    return "[from $(who)]\n\n" * sanitize_from_lines(text)
end

"""
    listen_attributed_message(msg, ch_name) -> SlackMessage

Listen-path variant of [`attribute_sender`](@ref): rebuild `msg` with its text
prefixed inline by sender and source channel —
`[from <@U0123ABCDE> in #general] <sanitized text>` — keeping the listen path's
single-line origin format while carrying the same authoritative-first,
forgeries-neutralized contract.
"""
function listen_attributed_message(msg::SlackMessage, ch_name::AbstractString)
    who = isempty(msg.user) ? "unknown" : "<@$(msg.user)>"
    text = "[from $(who) in #$(ch_name)] " * sanitize_from_lines(msg.text)
    return SlackMessage(msg.ts, msg.user, text, msg.thread_ts)
end
