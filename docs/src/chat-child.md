```@meta
CurrentModule = SlackClaw
```

# Chat Child

SlackClaw's chat child connects a supervising daemon to dedicated Slack apps.
It serves history, posts, file transfers and display events. It never constructs
`MonitorState`, runs an agent, interprets directives, schedules work or starts
proactive checks. The daemon owns project mapping, mail delivery, reconciliation,
attachment storage and process retirement. Existing monitor and fleet entry
points keep their own behavior.

Use one dedicated app per workspace, with no competing monitor or fleet using
that app. See [Dedicated chat apps](setup.md#Dedicated-chat-apps).

## Entry points and lifecycle

Launch a child with a private stdin pipe and drain both stdout and stderr:

```sh
julia --project=/path/to/SlackClaw -e 'using SlackClaw; chat_child_main()'
```

`chat_child_main()` reserves stdout for protocol frames and redirects incidental
prints to stderr. `run_chat_child(input::IO, output::IO; ...)` provides the same
service for embedding and tests, with injectable HTTP and socket transports.
Neither reads credentials from environment variables or configuration files.

1. `ready` means Julia has loaded the child, not that Slack is connected.
2. Send `configure` once. Its success means the complete configuration passed
   local validation. Authentication and socket connection happen afterward;
   watch `status` events. A rejected configuration can be corrected and sent
   again; a successful configuration cannot be replaced in this process.
3. API requests require an authenticated workspace and an allowed channel.
   `ping` and `stop` work before configuration and do not use API admission slots.
4. `stop` or stdin EOF ends admission, cancels further transport calls, closes
   queues and starts socket closure. Shutdown suppresses new event attempts;
   frames already waiting to write can finish. A stop request replies
   `{"stopped":true}` after outstanding replies
   have settled; EOF has no stop reply.

Shutdown drains workers until they exit or one second after the latest outstanding
request deadline, whichever comes first. Socket closure runs concurrently, using
the same bounded close as reconnect: one close task per socket waits up to two
seconds for the close handshake, then force-closes the underlying connection.
Workers that remain are reported in safe diagnostics. Cancellation is cooperative;
an HTTP call already running can still finish. A blocked stdout write can also
block shutdown.
The supervisor must own bounded retirement of a wedged child, even after the
caller has canceled. The child does not implement the daemon's startup allowance,
ping cadence, caller deadlines or process replacement policy.

## Envelope

Each UTF-8 JSON object occupies one line, terminated by a newline:

```json
{"v":1,"id":17,"kind":"req","op":"history","payload":{"workspace":"TEXAMPLE","channel":"CEXAMPLE"}}
{"v":1,"id":17,"kind":"res","op":"history","payload":{"messages":[]}}
{"v":1,"kind":"evt","op":"ready","payload":{"protocol":1}}
```

The protocol version is `1`, independent of the daemon's wire version. Request
IDs are JSON integers, excluding booleans; there is no positivity requirement.
Use a fresh ID for every request throughout the child's life. Responses echo the
ID and operation. Events have no ID. The payload must be an object. Operation
names match `[a-z][a-z0-9_.]*` and contain at most 64 bytes; invalid names become
an empty response operation.

An admitted worker and its deadline race for one response. At or past
`deadline_at`, the request counts as cancelled even if its timer callback has
not run. The reply owner also checks that deadline before attempting output:
a result obtained after it becomes `timeout`, never success. A mutation retains
a definite `refused` outcome when known; otherwise its deadline outcome is
`unknown`. A late result never adds a second reply. Reusing a pending API ID
produces a separate `bad_request` reply while the original request still owns its
reply, so clients must not reuse IDs. Other malformed envelopes with a usable ID
receive an error. Invalid JSON, missing or noninteger IDs and oversized input
lines are discarded with a safe diagnostic and no reply. Unknown operations
receive `bad_request`. Extra object fields are ignored.

## Requests

The following fields are required unless marked optional. In examples,
`TEXAMPLE`, `CEXAMPLE`, `UEXAMPLE` and `FEXAMPLE` are placeholders composed of
characters the validator accepts.

### configure

```json
{"workspaces":[{"id":"TEXAMPLE","bot_token":"xoxb-…","app_token":"xapp-…","channels":["CEXAMPLE"],"posting_form":"prefix"}]}
```

`workspaces` is an array of objects. Each `id` is a valid Slack identity and must
be unique. Each channel is also a valid identity, unique within that workspace.
Empty workspace and channel arrays are accepted. `posting_form` is explicitly
`custom` or `prefix`; the protocol has no default. Bot and app tokens must have
their respective `xoxb-` and `xapp-` prefixes, a nonempty suffix, no whitespace,
and at most 4,096 UTF-8 bytes each. Repeated app-token strings are rejected.
These are local format checks, not proof of live access.

Success: `{"accepted":true}`. Authentication uses `auth.test`, checks the
returned workspace ID, and saves the bot user and optional bot ID for origin
recognition. Requests before authentication receive `unavailable`.

Tokens reach the child only in this request on private stdin. Never put them in
argv, a row's environment, frontend payloads, mail or repository files. Output
frames redact configured credentials; diagnostics contain fixed event names and
exception types, never HTTP request dumps, private URLs or raw exceptions.
Configuration is the sole input frame that carries credentials.

### history

Payload: `{workspace, channel, thread_ts?, cursor?, before?, after?, until?, limit?}`.
`limit` defaults to 20 and must be an integer from 1 through 20, excluding
booleans. `thread_ts`, `before`, `after` and `until` may be absent or null;
otherwise they must be validated decimal timestamp strings. `before` and `until`
cannot be combined. `cursor` defaults to `""` and must be a string.

Success: `{messages, next_cursor?, limited?, omitted?}`. See
[History semantics](#History-semantics) and [Message record](#Message-record).

### post

Payload: `{workspace, channel, thread_ts?, text, author:{kind,name}}`.
`text` is a nonblank string of at most 8,192 UTF-8 bytes. `thread_ts` is absent,
null or a valid timestamp. Author validation and posting forms are described
under [Attribution](#Attribution).

Success: `{"ts":"1234567890.000001"}`, only after Slack acknowledges a valid
timestamp. The child submits `chat.postMessage` once. It does not verify thread
membership with a separate read; Slack handles the requested target. Failures
always carry a mutation outcome.

### file.fetch

Payload: `{workspace, channel, file_id, variant, destination, max_bytes}`.
`file_id` is a valid identity. `variant` is `original` or `thumbnail`.
`destination` is an absolute path of at most 4,096 UTF-8 bytes without NUL.
Its parent must exist and the destination must not exist, including as a symlink.
`max_bytes` is a positive integer within Julia's `Int` range, excluding booleans.

Success: `{bytes, mime}` after the file is fully written and closed. No private
URL or binary data enters the reply. See [File transfers](#File-transfers).

### file.upload

Payload: `{workspace, channel, thread_ts?, path, name, comment?, author:{kind,name}}`.
`path` has the same absolute-path validation as a fetch destination. It must
resolve to a nonempty regular file; source symlinks are followed. `name` is a
string of at most 256 UTF-8 bytes, nonempty after cleaning; `/` and `\` become
underscores. `comment` is absent, null or a string of at most 8,192 UTF-8 bytes.
`thread_ts` and `author` use the post validation rules.

Success: `{file_id, ts?}`, only after upload completion is acknowledged. The
timestamp is optional because Slack may omit share details. Upload failures
always carry a mutation outcome. File bytes stream outside JSON. There is no
child upload-size limit beyond the source checks, deadlines and Slack's response;
the caller owns storage and size policy.

### ping and stop

Send an empty object for either payload. `ping` replies `{}` independently of
Slack work. `stop` replies `{"stopped":true}` as described under lifecycle.
The implementation ignores extra fields in these payloads.

## History semantics

Without `thread_ts`, `conversations.history` walks backward: a continuation
returns older channel messages. With `thread_ts`, `conversations.replies` walks
forward from the parent. Each returned page is sorted by ascending exact decimal
timestamp, never floating point. A thread page may contain the parent in addition
to `limit` replies, so the maximum is 21 records. The parent is not promised on
every page and must pass the same time bounds as replies.

`after` and `before` are exclusive; `until` is inclusive. Bounds are also checked
locally, including the parent. For recovery, keep one fixed `until` throughout a
traversal. Channel history alone does not enumerate every old thread's replies;
the daemon must choose and verify its recovery traversal.

Treat `next_cursor` as opaque. It contains a versioned, base64-encoded Slack
continuation bound to the exact channel, thread, bounds and limit, including
defaults and nulls. Replay all those query values on subsequent requests, in
the same workspace. Workspace identity is selected by the envelope payload and
is not encoded into the cursor. The cursor is not an authorization token.
Changing a query field returns `bad_request`. A cursor over 1,024 bytes returns
`incomplete_history`, including when a newly generated cursor would exceed that
bound. Absence of `next_cursor` marks the end of the exposed traversal.

A Slack failure, malformed continuation, `has_more=true` without a continuation,
or raw page larger than the requested limit (plus a thread parent) fails the whole
request. Partial data is never returned as a successful final page. Malformed
individual message records are omitted instead, with an additive `omitted` count;
out-of-bounds messages do not count as omitted. This is not evidence that those
omitted records were delivered.

Slack's `is_limited=true` becomes the additive `limited:true` flag. The flag marks
history withheld by the workspace plan; it does not end pagination. Retention,
deletions and Slack access rules still limit what the daemon can recover.

## Message record

```json
{
  "workspace":"TEXAMPLE",
  "channel":"CEXAMPLE",
  "ts":"1234567890.000002",
  "thread_ts":"1234567890.000001",
  "author":{"id":"UEXAMPLE","name":"Person"},
  "origin":"member",
  "text":"message",
  "truncated":false,
  "reply_count":2,
  "latest_reply":"1234567890.000003",
  "files":[{"id":"FEXAMPLE","name":"figure.png","mime":"image/png","bytes":1234,"thumbnail":true}]
}
```

Top-level records default `thread_ts` to `ts`. `latest_reply` is included only
when Slack supplies it; an invalid supplied value omits the whole record.
`reply_count` defaults to zero when invalid. Invalid channel, timestamp, user or
bot identities omit the record; identity fields are never shortened. An absent
author can have an empty ID and the name `unknown` (member) or `bot`.

Origins are `member`, `drawer` (person through this app), `row` and `bot`.
Member names resolve through `users.info`, preferring display name, real name,
then login; failures fall back to the ID without caching the failure. Bot names
use username, then bot profile name, then `bot`. Bot messages remain visible.

Text is bounded at a UTF-8 character boundary and marked `truncated` when cut.
Each file summary has `id`, `name`, `mime`, `bytes` (integer or null) and a
`thumbnail` availability flag. Invalid file entries are skipped. More than eight
valid files adds `files_omitted`. A Slack Connect `check_file_info` stub retains
its ID with empty name/MIME, null size and `thumbnail:false`. Socket processing
tries `files.info` first; history can retain the unresolved stub. Private download
URLs and thumbnail URLs stay inside the child.

## Attribution

Authors have `kind:"person"` or `kind:"row"` and a raw `name` of at most 160
UTF-8 bytes that remains nonblank after cleaning. Row names gain a leading `@`
if needed and must still fit the limit. These are caller-supplied labels, not
personal Slack credentials.

Text posts always include metadata:

```json
{"event_type":"sot_chat_post","event_payload":{"kind":"person","name":"Person"}}
```

`custom` sets Slack's `username` to `Person (person via Ship of Tools)` or
`@handle (row via Ship of Tools)` and sends the text without a prefix. No icon
override is sent. `prefix` sends `Person (person via Ship of Tools): message`
or `@handle (row via Ship of Tools): message` under the app's normal author.
The 8,192-byte text limit applies before adding the label.

On readback, the bot user or bot ID must first match the authenticated app. Only
then does the child recognize metadata, a customized username suffix, or a text
prefix, in that order. Metadata kind `person` maps to `drawer`; `row` maps to
`row`. Unmarked own-app posts remain `bot`. Member text cannot claim own-app
origin. Text-prefix recognition removes that prefix from normalized text only
when metadata and customized username did not already identify the author.

The configured form is fixed for this child's life. The child never falls back
or repeats a failed post automatically. A caller may choose another form only
after a definite refusal, using a new configured child. Verify the chosen form
with live Socket Mode and history before deployment.

File shares always use the attribution label as `initial_comment`, followed by
`: comment` when a comment is supplied. They do not set customized usernames or
metadata, even for a `custom` workspace; the text prefix carries their origin.

## File transfers

Fetch resolves `files.info` and requires evidence the file is shared in the
requested channel (`channels`, `groups`, `ims`, or public/private `shares`).
Original selection prefers `url_private_download`, then `url_private`;
thumbnail selection prefers `thumb_360`, then `thumb_160`, then `thumb_480`.
Missing variants return `not_found`. Original metadata size and response
`Content-Length` are checked when present; the streaming sink always enforces
`max_bytes`, including when those hints are missing or wrong. An unexpected HTML
sign-in page returns `unauthorized`.

URLs must use HTTPS and have a host. Userinfo, ASCII characters through space,
DEL and backslashes are forbidden. Fetch follows at most five redirects,
resolving relative locations and revalidating every destination. It sends bot
authorization only to `slack.com` or a subdomain of `slack.com`; other HTTPS hosts
receive none. Rejected response bodies are discarded within a 64 KiB allowance
(HTTP.jl 2.x can close them without reading any bytes).

The destination is created exclusively with mode `0600`, and a failed transfer
removes its partial file if the same inode still occupies the path. The caller
owns and protects the parent folder. This does not protect against a party that
can change that folder, its ancestors or symlinks during the request. The child
does not choose cache names, enforce a folder quota, evict files or publish them
through a preview service.

Upload calls `files.getUploadURLExternal`, streams the regular file's original
bytes to its HTTPS upload URL without bot authorization or redirects, then calls
`files.completeUploadExternal` once to share it. No image re-encoding occurs.
The open source and path are checked for matching device, inode, size, mtime and
ctime before/after streaming. A change refuses sharing. Cooperative cancellation
is checked immediately before completion, including whether the request deadline
has passed even if its timer is late. An expired request will not start sharing;
a completion call already running can still finish, but a result obtained after
the deadline is never returned as success. Failures before completion begins
are `refused` for the channel share, even if unshared bytes reached Slack; after
completion begins they may be `unknown`.

## Events and socket behavior

| Operation | Payload |
|---|---|
| `ready` | `{protocol:1}` |
| `message` | A normalized message record, including bot posts |
| `changed` | `{workspace,channel,ts,change:"edit",message}` or `{workspace,channel,ts,change:"delete"}` |
| `status` | `{workspace,state,code?,detail?,retry_after_s?}` |
| `gap` | `{workspace,reason:"reconnected"}` or `{workspace,reason:"event_queue_overflow"}` |

The socket reader parses and acknowledges each envelope before queueing its
event, doing no HTTP work or protocol output on the acknowledgement path. One
FIFO consumer per workspace normalizes configured channels. Supported message
subtypes are absent/empty, `thread_broadcast`, `file_share`, `bot_message` and
`me_message`; edits and deletes use `changed`. Other subtypes are ignored.

The queue holds 256 events by default. Overflow drops the event and emits a
`gap` once for that overflow stretch; it never waits for queue space. Socket
reconnects also emit a gap after a later `hello`. Neither gap promises catch-up;
the daemon must reconcile. Event output is detached from acknowledgements, so
event tasks can accumulate if the supervisor stops draining stdout.

States are `connecting`, `connected`, `reconnecting`, `limited` and `unavailable`.
`connected` follows Slack's `hello`. Authentication failures report `unavailable`
and wait 30 seconds; rate limits report `limited` and respect `Retry-After`.
Ordinary reconnect delay doubles from one second to 30 seconds and resets after
60 seconds of connection service. A disconnect `warning` keeps serving; other
disconnects reconnect. Reconnect and shutdown share one bounded close task per
socket: the close handshake runs in its own task, with a two-second wait before
the underlying connection is force-closed. Reconnect waits for that retirement
step, so a peer that never answers the handshake cannot hold up the next connection.

Besides rejecting repeated app-token strings at configuration, the child checks
`hello.connection_info.app_id` against other active workspace connections. A
duplicate emits `unavailable` with `code:"duplicate_app"` and disables that
runtime. This check cannot detect another process using the app; dedicated apps
remain required.

## Errors and bounds

Error payloads use `{error, code, retry_after_s?, outcome?}`. Explanations are
cleaned and bounded to 256 UTF-8 bytes. Codes are `bad_request`, `unauthorized`,
`forbidden`, `not_found`, `incomplete_history`, `rate_limited`, `busy`, `too_large`,
`io_error`, `timeout` and `unavailable`; `duplicate_app` appears in status events.
`retry_after_s` accompanies rate limits; absent or invalid `Retry-After` defaults
to 30 seconds. HTTP exceptions are mapped by type without exposing their text.

Every failed `post` or `file.upload` includes `outcome:"refused"` for a definite
refusal or `outcome:"unknown"` when the mutation may have happened. Successful
mutations return their operation-specific result without an `outcome` field.
Reads omit outcomes. Timeouts, lost responses, malformed acknowledgements and
server failures can make a mutation unknown. Inspect Slack/history before any
further action; never automatically repeat an unknown mutation. The chat client
does not retry or sleep on API rate limits. Socket reconnection has its separate
backoff described above.

| Bound | Default or rule |
|---|---|
| Protocol input/output line | 1 MiB encoded JSON, excluding newline; `max_line` can override, minimum 256 bytes |
| Identity | 1–64 uppercase ASCII letters or digits (`[A-Z0-9]`); underscores are invalid |
| Timestamp | At most 32 bytes, `[0-9]{1,20}\.[0-9]{1,10}` |
| Author name / filename | 160 / 256 UTF-8 bytes |
| MIME | Valid type/subtype, up to 64 ASCII bytes each and 128 bytes total including `/`; lowercased, parameters removed; invalid or recognizable secret values become `application/octet-stream` (unresolved stubs use `""`) |
| Message text / file summaries | 8,192 UTF-8 bytes / eight files |
| Serialized record | At most 32 KiB JSON; text can shrink further to fit escaping |
| Page | `limit` 1–20; thread parent can add one record |
| Cursor / path | 1,024 / 4,096 bytes |
| API admission | 16 active workers total, including at most two file transfers; excess returns `busy` |
| Metadata HTTP timeout / request deadline | 20 / 25 seconds |
| File HTTP timeout / request deadline | 120 / 125 seconds |

HTTP timeouts bound connection/read waits in each transport call, not the total
sequence of API calls; HTTP.jl 1.x rounds fractional timeouts up to seconds.
Request cancellation and reply ownership also check the absolute deadline, so a
delayed timer cannot permit a late success. These checks are cooperative: they cannot interrupt a
blocked output write or a non-yielding transport, and do not roll back work
already in progress. A timed-out worker retains its admission slot until it
actually exits.

If a frame write or flush throws, the child treats the daemon's stdout reader as
gone: it begins shutdown, closes stdin to wake the protocol reader, and releases
an admitted request's ID and reply accounting even when its reply failed.
Further frame writes are suppressed and no stop reply is attempted after output
failure. Diagnostics report a fixed event name and exception type only. This is
distinct from an output write that blocks without throwing, which still needs
supervisor retirement.

Oversized replies become `too_large` (with an appropriate mutation outcome);
if even that envelope cannot fit, it is dropped with a diagnostic. Oversized
events are also dropped with a diagnostic. These line bounds do not cap incoming
Slack HTTP bodies, websocket frames, name caches or the number of detached
event-output tasks.
