# Explicit Trigger and Timeout Design

## Goal

Change `cursor-code-review` from an automatic post-implementation workflow to
an explicitly requested tool. Make a stalled Cursor CLI invocation visible and
bounded without changing the selected review model.

## Trigger

The skill activates only when the user explicitly asks for external Cursor
review, including:

- `$cursor-code-review`;
- `/cursor-code-review`;
- "run Cursor review" or "запусти Cursor review";
- "review through Cursor" or "проверь через Cursor".

Generic implementation work, task completion, "review this code", and ordinary
verification do not activate the skill unless Cursor is explicitly named.

The skill remains in `~/.agents/skills` and uses portable Agent Skills metadata.
It does not use Cursor-specific `disable-model-invocation`, because that would
make discovery inconsistent across compatible agent harnesses.

## Review Workflow

Each explicit request starts exactly one Cursor review. The calling agent:

1. Runs local verification when relevant.
2. Invokes `scripts/review.sh` once.
3. Validates and reports Cursor findings.
4. Does not automatically fix and re-review.

A second review requires another explicit user request. There is no automatic
retry after findings, operational failure, or timeout.

## Timeout and Progress

The runner starts Cursor Agent in the background and emits a progress heartbeat
to standard error every 30 seconds while it remains active.

The default timeout is 600 seconds. Tests may override it with
`CURSOR_REVIEW_TIMEOUT_SECONDS`; the value must be a positive integer. At the
deadline the runner terminates Cursor, reports the timeout, and exits `2`.

Timeout remains an operational failure, never approval. Existing worktree
fingerprinting still runs after Cursor terminates so persistent reviewer changes
cannot be hidden by a timeout.

## Cursor Invocation

The review continues to use:

```text
agent -p
--mode=ask
--trust
--sandbox=enabled
--model cursor-grok-4.5-high
--output-format=json
```

The model remains non-Fast. No quota fallback or automatic model substitution is
added.

## Error Handling

- Authentication, quota, API, malformed JSON, timeout, and mutation failures
  return exit `2`.
- The runner preserves useful Cursor stderr.
- Timeout diagnostics state the elapsed limit.
- No failure triggers an automatic retry.

## Testing

Shell tests verify:

- explicit-only trigger language in `SKILL.md`;
- exactly one review in the documented workflow;
- default timeout of 600 seconds;
- positive-integer timeout validation;
- heartbeat output while a fake agent is active;
- a fake hung agent is terminated and maps to exit `2`;
- existing PASS, FAIL, protocol, read-only, and mutation protections remain
  green.

No live Cursor review is run automatically for this change. The user explicitly
requested that reviews occur only on demand.
