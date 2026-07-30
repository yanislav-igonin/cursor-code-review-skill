# Streamed Cursor Review Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream sanitized Cursor activity while preserving the existing final verdict, safety, and timeout contract.

**Architecture:** Cursor writes NDJSON to a temporary FIFO while remaining a directly managed process-group leader. The main shell validates and records each event, emits only coarse operational statuses, and updates a shared activity timestamp read by the existing timeout monitor. After EOF, the runner fingerprints the worktree and accepts exactly one successful terminal result.

**Tech Stack:** Bash 3.2+, Cursor Agent CLI, NDJSON, jq, Git, awk, mkfifo

## Global Constraints

- Invoke exactly `cursor-grok-4.5-high`, without Fast.
- Use `--mode=ask`, `--sandbox=enabled`, and never `--force` or `--yolo`.
- Use `--output-format=stream-json`; do not use `--stream-partial-output`.
- Print sanitized progress to stderr and final review text to stdout.
- Never print assistant deltas, prompts, tool arguments, paths, contents, results, or credentials.
- Default heartbeat remains 30 seconds and hard timeout remains 600 seconds.
- Stream idleness is diagnostic only and never triggers termination.
- Exactly one successful terminal result and one standalone verdict are required.
- Worktree mutation, timeout, malformed stream, missing result, duplicate result, and CLI failure return exit `2`.
- One explicit request runs exactly one review with no automatic retry.

---

### Task 1: Streaming fixture and progress contract

**Files:**
- Modify: `tests/review_test.sh`
- Modify: `scripts/review.sh`

**Interfaces:**
- Consumes: NDJSON events on Cursor stdout.
- Produces: sanitized progress on stderr, raw events in a private temporary file, and an activity timestamp for the monitor.

- [ ] **Step 1: Extend the fake agent for early events**

Add `AGENT_EARLY_OUTPUT` to fixture cleanup. Before the fake agent sleeps, emit
it only when non-empty:

```bash
if [[ -n "${AGENT_EARLY_OUTPUT:-}" ]]; then
  printf "%s\n" "$AGENT_EARLY_OUTPUT"
fi
```

- [ ] **Step 2: Add failing streaming tests**

Update the command contract to require `--output-format=stream-json` and reject
`--stream-partial-output`.

Add a test that starts the runner in the background with early `system`,
`tool_call`, `assistant`, `connection`, and unknown events, followed one second
later by a terminal PASS event. Before the process exits, assert stderr already
contains:

```text
Cursor session started
Cursor tool started: readToolCall
Cursor tool completed: readToolCall
Cursor connection reconnecting
```

Assert stderr does not contain secret assistant text, tool paths, tool results,
API-key source, or unknown-event payloads.

- [ ] **Step 3: Run the suite and verify RED**

Run:

```bash
bash tests/review_test.sh
```

Expected: command contract and progress tests fail because the runner still
uses aggregate JSON and emits only synthetic heartbeat text.

- [ ] **Step 4: Implement FIFO event consumption**

Create temporary `stream_file`, `activity_file`, and `stream_pipe`. Add all
three to cleanup. Initialize activity with `date +%s` and create the pipe with
`mkfifo`.

Start Cursor with:

```bash
--output-format=stream-json
```

redirected to `"$stream_pipe"`.

Read the pipe in the main shell. For every line:

1. append it to `stream_file`;
2. require valid JSON whose top level is an object;
3. update `activity_file`;
4. print only fixed messages for `system:init`, `tool_call:started`,
   `tool_call:completed`, and recognized `connection`/`retry` subtypes;
5. sanitize tool kind to `[A-Za-z0-9_-]+`;
6. silently record assistant and unknown events.

Track malformed input with `stream_parse_failed=1` and continue draining the
pipe so Cursor cannot block on a full writer.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
bash tests/review_test.sh
```

Expected: all existing tests plus streaming progress tests pass.

### Task 2: Activity-aware heartbeat and terminal protocol

**Files:**
- Modify: `tests/review_test.sh`
- Modify: `scripts/review.sh`

**Interfaces:**
- Consumes: `activity_file` epoch seconds and completed `stream_file`.
- Produces: activity-aware heartbeat plus exactly one validated final result.

- [ ] **Step 1: Add failing activity and terminal tests**

Add assertions that a heartbeat contains:

```text
last Cursor event <N>s ago
```

Add tests for:

- a valid unknown event followed by one PASS result succeeds;
- malformed NDJSON returns exit `2`;
- no terminal result returns exit `2`;
- two terminal result events return exit `2`;
- a terminal event whose subtype/is_error/result is invalid returns exit `2`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/review_test.sh
```

Expected: activity heartbeat, missing-result, and duplicate-result contracts
fail against aggregate parsing.

- [ ] **Step 3: Implement activity-aware heartbeat**

At each heartbeat, read the activity epoch defensively. If it is numeric, print:

```text
cursor-code-review: review still running (<elapsed>s; last Cursor event <idle>s ago)
```

If a concurrent write makes it temporarily invalid, print `last Cursor event
unknown`. Do not change timeout behavior based on idle duration.

- [ ] **Step 4: Implement terminal stream validation**

After fingerprint, timeout, and non-zero-agent checks:

1. fail if any stream line was malformed;
2. use `jq -s` to count every event with `.type == "result"`;
3. require the count to equal one;
4. require that event to have `subtype == "success"`, `is_error == false`, and a
   string `result`;
5. pass the extracted text through the existing standalone-verdict parser.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
bash tests/review_test.sh
bash -n scripts/review.sh tests/review_test.sh
git diff --check
```

Expected: full suite passes; syntax and whitespace checks exit `0`.

### Task 3: Skill documentation, validation, and live review

**Files:**
- Modify: `SKILL.md`
- Modify: `tests/review_test.sh`

**Interfaces:**
- Consumes: completed streamed runner.
- Produces: accurate operator guidance, committed feature branch, and one explicitly requested live Cursor review.

- [ ] **Step 1: Add a failing skill documentation contract**

Require `SKILL.md` to state that progress is sanitized, heartbeat reports last
Cursor event age, assistant/tool content is not exposed, and idle alone does
not stop the review.

- [ ] **Step 2: Update SKILL.md**

Document streamed progress and add `mkfifo` and `date` to compatibility. Keep
the explicit-only and one-shot workflow unchanged.

- [ ] **Step 3: Run fresh local verification**

Run:

```bash
bash tests/review_test.sh
bash -n scripts/review.sh tests/review_test.sh
uv run --with pyyaml python \
  /Users/h0b0/.agents/skills/skill-creator/scripts/quick_validate.py \
  /Users/h0b0/Documents/private/cursor-code-review-skill
git diff --check
test "$(readlink /Users/h0b0/.agents/skills/cursor-code-review)" = \
  "/Users/h0b0/Documents/private/cursor-code-review-skill"
```

- [ ] **Step 4: Commit implementation**

```bash
git add SKILL.md scripts/review.sh tests/review_test.sh \
  docs/superpowers/plans/2026-07-30-stream-json-progress.md
git commit -m "feat: stream Cursor review progress"
```

- [ ] **Step 5: Run one explicit live Cursor review**

Invoke the updated `scripts/review.sh` exactly once with the design requirements
and fresh verification evidence. Confirm progress events appear before the
terminal result. Report the complete finding summary and final verdict to the
user. Do not automatically fix and re-review.

- [ ] **Step 6: Finish branch**

Report the local commit and live-review result. Keep
`feature/stream-json-progress` available for the user; do not push or open a PR
without a separate request.
