# Streamed Cursor Review Progress Design

## Goal

Replace the current aggregate Cursor CLI response with structured real-time
events so the caller can distinguish useful reviewer activity from a live but
silent process.

The runner continues to produce the same final review text and exit codes. The
change adds progress visibility without weakening the existing read-only,
timeout, mutation, and verdict protections.

## Scope

The runner will:

- invoke Cursor with `--output-format=stream-json`;
- omit `--stream-partial-output`;
- consume newline-delimited JSON as Cursor emits it;
- print sanitized progress to standard error;
- keep final review text on standard output;
- report time since the most recent Cursor event in each heartbeat;
- retain the 600-second hard timeout;
- retain exactly one review per explicit user request.

The runner will not:

- expose hidden model reasoning;
- print assistant text deltas, tool arguments, file contents, or tool results;
- kill a review only because the event stream has been idle;
- retry, resume, or start another Cursor session automatically;
- treat progress events as approval.

## Command

The Cursor invocation remains read-only and non-Fast:

```bash
CURSOR_REVIEW_ACTIVE=1 agent -p \
  --mode=ask \
  --trust \
  --sandbox=enabled \
  --model cursor-grok-4.5-high \
  --output-format=stream-json \
  --workspace "$repo_root" \
  "$prompt"
```

The runner does not pass `--stream-partial-output`. Event-level progress is
useful; token-sized assistant deltas are noisy and have a less stable shape.

## Data Flow

The agent writes NDJSON to a temporary FIFO. It remains a directly managed
background process so the existing process-group timeout and cleanup logic can
terminate it and its descendants.

The main shell reads the FIFO one line at a time:

1. Validate the line as one JSON object.
2. Append the original line to a private temporary stream file.
3. Update a shared last-activity timestamp.
4. Emit a sanitized status for recognized operational events.
5. Ignore unknown event types after recording them.

At end of stream, the runner waits for Cursor and stops the timeout monitor. It
then performs the existing post-review worktree fingerprint check before
interpreting the terminal event.

## Progress Output

Progress is written only to standard error. The final human-readable Cursor
review remains on standard output.

Recognized statuses are intentionally coarse:

```text
cursor-code-review: Cursor session started
cursor-code-review: Cursor tool started: readToolCall
cursor-code-review: Cursor tool completed: readToolCall
cursor-code-review: Cursor connection reconnecting
cursor-code-review: review still running (120s; last Cursor event 18s ago)
```

The runner may include a documented event subtype or tool kind. It must not
print prompt text, assistant deltas, tool arguments, paths, file contents, tool
results, credentials, or raw unknown events.

Every valid Cursor event updates activity, including assistant and unknown
events that are not printed. This measures stream liveness without leaking
their content.

## Heartbeat and Timeout

The existing monitor keeps two clocks:

- total elapsed time since Cursor started;
- seconds since the most recent valid Cursor event.

Every 30 seconds it prints both values. An idle stream is diagnostic only:
Grok 4.5 High may legitimately spend a long period inside one model call.

At 600 seconds total elapsed time, the monitor preserves the existing behavior:

1. mark the run timed out;
2. send `TERM` to the Cursor process group;
3. fall back to the direct PID if group signaling fails;
4. wait up to five seconds;
5. send `KILL` if Cursor remains alive;
6. return exit `2` after worktree mutation detection.

## Terminal Result

A successful stream must contain exactly one terminal event matching:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "<text>"
}
```

The runner extracts `result` only from that event, prints it, and applies the
existing exactly-one-standalone-verdict rule:

- `VERDICT: PASS` maps to exit `0`;
- `VERDICT: FAIL` maps to exit `1`;
- missing, duplicate, malformed, or contradictory terminal data maps to exit
  `2`.

A non-zero Cursor exit, malformed NDJSON line, premature EOF without a terminal
result, or multiple terminal results is an operational failure. Cursor standard
error is preserved for those failures.

## Reconnects and Unknown Events

Cursor may add backward-compatible fields and event types. The parser therefore
uses only documented fields and ignores unknown fields.

Connection and retry events are surfaced as sanitized statuses when their type
and subtype are available. The runner does not require every
`tool_call:started` event to have a matching `tool_call:completed` event because
Cursor reconnects may omit the completion event. The terminal result, process
exit, timeout marker, and worktree fingerprint remain authoritative.

## Failure Safety

- The FIFO, raw stream, activity timestamp, stderr file, and timeout marker are
  private temporary files removed by the existing cleanup trap.
- Cleanup terminates the monitor and Cursor process groups before removing
  temporary files.
- A stream parser error does not bypass the after-review fingerprint.
- Progress output cannot satisfy or alter verdict parsing.
- The runner never writes a temporary file inside the reviewed repository.

## Testing

The fake Cursor agent will emit delayed NDJSON events and optionally spawn a
long-lived child. Tests will cover:

- progress is visible before the terminal result;
- tool start and completion produce sanitized statuses;
- assistant deltas, tool arguments, paths, and results are not leaked;
- heartbeat reports time since the latest event;
- unknown and reconnect events do not break parsing;
- malformed lines, missing result, and duplicate terminal results return exit
  `2`;
- PASS and FAIL retain their current exit mappings;
- Cursor stderr survives operational failures;
- timeout still terminates the fake agent and its child;
- worktree mutation still overrides a successful verdict;
- model, Ask mode, sandbox, recursion guard, explicit trigger, and one-shot
  behavior remain unchanged.

No live Cursor review runs automatically while implementing this design. A live
review requires another explicit user request.
