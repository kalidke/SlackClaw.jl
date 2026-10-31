"""A download sink that remembers overflow even when HTTP.jl wraps its exception."""
mutable struct ChatFileSink <: IO
    io::IO
    max_bytes::Int
    bytes::Int
    exceeded::Bool
end

function Base.unsafe_write(sink::ChatFileSink, data::Ptr{UInt8}, count::UInt)
    if count > UInt(sink.max_bytes - sink.bytes)
        sink.exceeded = true
        throw(ChatError(:too_large, "File exceeds max_bytes"))
    end
    written = unsafe_write(sink.io, data, count)
    sink.bytes += Int(written)
    return written
end

Base.write(sink::ChatFileSink, byte::UInt8) = write(sink, Ref(byte))
Base.isopen(sink::ChatFileSink) = isopen(sink.io)
Base.iswritable(sink::ChatFileSink) = iswritable(sink.io)

"""Validate caller-owned paths without ever echoing their contents."""
function chat_file_path(value, field::AbstractString)
    value isa AbstractString && ncodeunits(value) <= 4096 && !occursin('\0', value) && isabspath(value) ||
        throw(ChatError(:bad_request, "Invalid $field"))
    return String(value)
end

"""Keep file errors private, including untrusted Slack API error strings."""
function chat_file_exception(ws::ChatWorkspace, e; mutation::Bool=false)
    err = chat_exception(e; mutation)
    detail = err.detail
    for token in (ws.bot_token, ws.app_token)
        isempty(token) || (detail = replace(detail, token => "[redacted]"))
    end
    detail = replace(detail, r"[A-Za-z][A-Za-z0-9+.-]*://\S+" => "[private URL]")
    return ChatError(err.code, detail, err.retry_after_s, mutation ? err.outcome : :none)
end

"""Read one response header case-insensitively."""
function chat_file_header(headers::AbstractVector, name::AbstractString)
    for (key, value) in headers
        lowercase(key) == name && return String(value)
    end
    return ""
end

"""Parse a private URL without letting HTTP add credentials from URL userinfo."""
function chat_file_url(value)
    value isa AbstractString && !isempty(value) || throw(ChatError(:io_error, "Missing file URL"))
    any(c -> c <= ' ' || c == '\x7f' || c == '\\', value) &&
        throw(ChatError(:forbidden, "Invalid file URL"))
    uri = try
        HTTP.URIs.URI(value)
    catch
        throw(ChatError(:forbidden, "Invalid file URL"))
    end
    lowercase(uri.scheme) == "https" || throw(ChatError(:forbidden, "File URL must use HTTPS"))
    !isempty(uri.host) && isempty(uri.userinfo) || throw(ChatError(:forbidden, "Invalid file URL host"))
    return HTTP.URIs.URI(uri; scheme="https", host=lowercase(uri.host))
end

"""Check the channel membership in both Slack file metadata representations."""
function chat_file_shared(file::AbstractDict, channel::String)
    for field in ("channels", "groups", "ims")
        channels = get(file, field, nothing)
        channels isa AbstractVector && channel in channels && return true
    end
    shares = get(file, "shares", nothing)
    if shares isa AbstractDict
        for field in ("public", "private")
            channels = get(shares, field, nothing)
            channels isa AbstractDict && haskey(channels, channel) && return true
        end
    end
    return false
end

"""Map a file server's status without reflecting its URL or response body."""
function chat_file_status(status::Int, headers::AbstractVector)
    code = status == 401 ? :unauthorized : status == 403 ? :forbidden :
           status == 404 ? :not_found : status == 429 ? :rate_limited :
           status >= 500 ? :unavailable : :io_error
    return ChatError(code, "File server HTTP $status", code == :rate_limited ? chat_retry_after(headers) : nothing)
end

"""Resolve file metadata once, including Slack Connect stubs, without exposing URLs."""
function chat_file_info(ws::ChatWorkspace, file_id; timeout_s::Real=20)
    id = chat_validate(file_id, "file_id")
    data = chat_api(ws, "GET", "files.info"; query=Dict{String,Any}("file" => id), timeout_s)
    file = get(data, "file", nothing)
    file isa AbstractDict || throw(ChatError(:io_error, "Slack omitted file metadata"))
    return file
end

"""
    chat_fetch_file(ws, req::AbstractDict) -> Dict{String,Any}

Resolve a channel's private Slack file and stream bounded bytes into an exclusively
created destination. Redirects are manual so only Slack hosts receive the token.
The destination's parent directory belongs to the caller (the daemon). The final
path must not already be a file or symlink. This call does not defend against a
party able to write in that directory, including ancestor symlinks or a file
swapped in before cleanup.
"""
function chat_fetch_file(ws::ChatWorkspace, req::AbstractDict; timeout_s::Real=120)
    try
        channel = chat_validate(get(req, "channel", nothing), "channel")
        file_id = chat_validate(get(req, "file_id", nothing), "file_id")
        variant = get(req, "variant", nothing)
        variant in ("original", "thumbnail") || throw(ChatError(:bad_request, "Invalid file variant"))
        destination = chat_file_path(get(req, "destination", nothing), "destination")
        isdir(dirname(destination)) || throw(ChatError(:bad_request, "Destination parent must exist"))
        (ispath(destination) || islink(destination)) && throw(ChatError(:bad_request, "Destination already exists"))
        max_bytes = get(req, "max_bytes", nothing)
        max_bytes isa Integer && !(max_bytes isa Bool) && 0 < max_bytes <= typemax(Int) ||
            throw(ChatError(:bad_request, "Invalid max_bytes"))
        max_bytes = Int(max_bytes)

        file = chat_file_info(ws, file_id; timeout_s)
        chat_file_shared(file, channel) || throw(ChatError(:forbidden, "File is not shared in the channel"))
        if variant == "original"
            size = get(file, "size", nothing)
            size isa Integer && !(size isa Bool) && size > max_bytes &&
                throw(ChatError(:too_large, "File exceeds max_bytes"))
        end
        fields = variant == "original" ? ("url_private_download", "url_private") : ("thumb_360", "thumb_160", "thumb_480")
        url = ""
        for field in fields
            url = chat_string(file, field)
            isempty(url) || break
        end
        isempty(url) && throw(ChatError(:not_found, "Requested file variant is unavailable"))
        original_mime = chat_file_mime(chat_string(file, "mimetype"))
        mime = original_mime
        sink = nothing
        output = nothing
        owned = nothing
        complete = false
        callback_error = nothing
        try
            for hop in 0:5
                uri = chat_file_url(url)
                headers = Pair{String,String}[]
                (uri.host == "slack.com" || endswith(uri.host, ".slack.com")) &&
                    push!(headers, "Authorization" => "Bearer $(ws.bot_token)")
                select_sink = function(status::Int, response_headers::Vector{Pair{String,String}})
                    try
                        status == 200 || return nothing
                        response_mime = chat_file_mime(chat_file_header(response_headers, "content-type"))
                        if response_mime == "text/html" && chat_file_mime(original_mime) != "text/html"
                            throw(ChatError(:unauthorized, "Slack returned a sign-in page instead of the file"))
                        end
                        content_length = tryparse(BigInt, strip(chat_file_header(response_headers, "content-length")))
                        content_length !== nothing && content_length > max_bytes &&
                            throw(ChatError(:too_large, "File exceeds max_bytes"))
                        output = try
                            Base.Filesystem.open(destination,
                                Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL, 0o600)
                        catch e
                            e isa Base.IOError && e.code == Base.UV_EEXIST &&
                                throw(ChatError(:bad_request, "Destination already exists"))
                            rethrow()
                        end
                        owned = stat(output)
                        sink = ChatFileSink(output, max_bytes, 0, false)
                        mime = variant == "original" ? original_mime : response_mime
                        return sink
                    catch e
                        callback_error = e
                        rethrow()
                    end
                end
                response = try
                    ws.transport("GET", string(uri), headers; response_stream=select_sink, timeout_s)
                catch
                    sink !== nothing && sink.exceeded && throw(ChatError(:too_large, "File exceeds max_bytes"))
                    callback_error === nothing || throw(callback_error)
                    rethrow()
                end
                sink !== nothing && sink.exceeded && throw(ChatError(:too_large, "File exceeds max_bytes"))
                callback_error === nothing || throw(callback_error)
                if response.status in (301, 302, 303, 307, 308)
                    hop == 5 && throw(ChatError(:io_error, "Too many file redirects"))
                    location = chat_file_header(response.headers, "location")
                    isempty(location) && throw(ChatError(:io_error, "File redirect omitted Location"))
                    url = try
                        string(HTTP.URIs.resolvereference(uri, location))
                    catch
                        throw(ChatError(:forbidden, "Invalid file redirect"))
                    end
                    continue
                end
                response.status == 200 || throw(chat_file_status(response.status, response.headers))
                sink === nothing && throw(ChatError(:io_error, "Transport did not stream the file"))
                close(output)
                complete = true
                return Dict{String,Any}("bytes" => sink.bytes, "mime" => mime)
            end
        finally
            try
                output === nothing || close(output)
            finally
                if !complete && owned !== nothing
                    # Do not remove a replacement path or a symlink planted during the request.
                    current = lstat(destination)
                    if !islink(current) && current.device == owned.device && current.inode == owned.inode
                        rm(destination)
                    end
                end
            end
        end
    catch e
        throw(chat_file_exception(ws, e))
    end
end

"""Compare source identity, size, modification time and metadata change time."""
chat_file_unchanged(before, after) = isfile(after) && before.size == after.size &&
    before.mtime == after.mtime && before.ctime == after.ctime &&
    before.device == after.device && before.inode == after.inode

"""Extract an optional completion share timestamp from either Slack share category."""
function chat_file_share_ts(data::AbstractDict, channel::String)
    files = get(data, "files", nothing)
    files isa AbstractVector && !isempty(files) || return nothing
    file = first(files)
    file isa AbstractDict || return nothing
    shares = get(file, "shares", nothing)
    shares isa AbstractDict || return nothing
    for field in ("public", "private")
        channels = get(shares, field, nothing)
        channels isa AbstractDict || continue
        entries = get(channels, channel, nothing)
        entries isa AbstractVector && !isempty(entries) || continue
        share = first(entries)
        share isa AbstractDict || continue
        ts = get(share, "ts", nothing)
        chat_valid_ts(ts) && return String(ts)
    end
    return nothing
end

"""
    chat_upload_file(ws, req::AbstractDict; timeout_s=120, cancelled=() -> false) -> Dict{String,Any}

Stream the source's original bytes without sharing until its identity, size and
mtime/ctime have been checked again. Complete exactly once, preserving uncertainty.
Check cooperative cancellation immediately before sharing the uploaded file.
"""
function chat_upload_file(ws::ChatWorkspace, req::AbstractDict;
                          timeout_s::Real=120, cancelled::Function=() -> false)
    completion_started = false
    try
        channel = chat_validate(get(req, "channel", nothing), "channel")
        thread_ts = get(req, "thread_ts", nothing)
        thread_ts === nothing || (thread_ts = chat_validate(thread_ts, "thread_ts"; timestamp=true))
        path = chat_file_path(get(req, "path", nothing), "path")
        before = stat(path)
        isfile(before) || throw(ChatError(:bad_request, "Source must be a regular file"))
        before.size > 0 || throw(ChatError(:bad_request, "Source file is empty"))
        raw_name = get(req, "name", nothing)
        raw_name isa AbstractString && ncodeunits(raw_name) <= 256 || throw(ChatError(:bad_request, "Invalid file name"))
        name = replace(clean_field(raw_name), '/' => '_', '\\' => '_')
        isempty(name) && throw(ChatError(:bad_request, "File name is required"))
        comment = get(req, "comment", nothing)
        comment === nothing || comment isa AbstractString || throw(ChatError(:bad_request, "Invalid comment"))
        comment === nothing || ncodeunits(comment) <= 8192 || throw(ChatError(:too_large, "Comment exceeds 8192 bytes"))
        _, _, label = chat_author_label(get(req, "author", nothing))

        data = chat_api(ws, "GET", "files.getUploadURLExternal";
            query=Dict{String,Any}("filename" => name, "length" => before.size), timeout_s)
        file_id = get(data, "file_id", nothing)
        chat_valid_id(file_id) || throw(ChatError(:io_error, "Slack omitted a valid upload file ID"))
        upload_url = chat_file_url(get(data, "upload_url", nothing))
        input = open(path, "r")
        try
            chat_file_unchanged(before, stat(input)) || throw(ChatError(:io_error, "source changed during upload"))
            response = ws.transport("POST", string(upload_url), Pair{String,String}[
                "Content-Type" => "application/octet-stream", "Content-Length" => string(before.size)];
                body=input, timeout_s)
            200 <= response.status < 300 || throw(chat_file_status(response.status, response.headers))
            chat_file_unchanged(before, stat(input)) && chat_file_unchanged(before, stat(path)) ||
                throw(ChatError(:io_error, "source changed during upload"))
        finally
            close(input)
        end
        body = Dict{String,Any}("files" => [Dict{String,Any}("id" => file_id, "title" => name)],
            "channel_id" => channel, "initial_comment" => comment === nothing ? label : "$label: $comment")
        thread_ts === nothing || (body["thread_ts"] = thread_ts)
        cancelled() && throw(ChatError(:timeout, "upload cancelled before sharing", nothing, :refused))
        completion_started = true
        data = chat_api(ws, "POST", "files.completeUploadExternal"; body, mutation=true, timeout_s)
        result = Dict{String,Any}("file_id" => String(file_id))
        ts = chat_file_share_ts(data, channel)
        ts === nothing || (result["ts"] = ts)
        return result
    catch e
        err = chat_file_exception(ws, e; mutation=completion_started)
        throw(completion_started ? err : ChatError(err.code, err.detail, err.retry_after_s, :refused))
    end
end
