# Explicit Cursor Review Trigger and Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cursor review explicitly requested, single-shot, visible while running, and bounded by a ten-minute timeout.

**Architecture:** `SKILL.md` narrows discovery to explicit Cursor-review requests and documents one invocation with no automatic retry. `scripts/review.sh` runs Cursor in the background, writes aggregate JSON to a temporary file, emits periodic stderr heartbeats, and terminates a stalled process at the configured deadline. Existing verdict parsing, sandboxing, and worktree-mutation detection remain unchanged.

**Tech Stack:** Agent Skills metadata, Bash 3.2+, Git CLI, Cursor Agent CLI, awk, jq

## Global Constraints

- Trigger only when the user explicitly names Cursor review or invokes `$cursor-code-review`/`/cursor-code-review`.
- Generic implementation, completion, verification, and generic code-review requests must not trigger the skill.
- One explicit request runs exactly one external review.
- No automatic retry, fix-and-review loop, or model fallback.
- Default timeout is exactly 600 seconds.
- Heartbeat interval is exactly 30 seconds by default.
- Model remains exactly `cursor-grok-4.5-high`, without Fast.
- Timeout and other operational failures return exit `2`, never PASS.
- Do not automatically run a live Cursor review while implementing this change.

---

### Task 1: Explicit-only single-review skill contract

**Files:**
- Modify: `SKILL.md`
- Modify: `tests/review_test.sh`

**Interfaces:**
- Consumes: explicit user requests naming Cursor review.
- Produces: Agent Skills metadata that does not match ordinary implementation completion, plus a one-invocation workflow.

- [ ] **Step 1: Add a failing metadata/workflow contract test**

Add this test and registration to `tests/review_test.sh`:

```bash
test_skill_requires_explicit_cursor_request() {
  local skill="$ROOT/SKILL.md"
  grep -Fq -- 'only when the user explicitly requests' "$skill" &&
    grep -Fq -- '$cursor-code-review' "$skill" &&
    grep -Fq -- '/cursor-code-review' "$skill" &&
    grep -Fq -- 'Run `scripts/review.sh` exactly once' "$skill" &&
    grep -Fq -- 'A new explicit user request is required for another review' "$skill" &&
    ! grep -Fq -- 'before claiming the task is finished' "$skill" &&
    ! grep -Fq -- 'maximum of three review cycles' "$skill"
}

run_test "skill requires explicit Cursor request and one review" \
  test_skill_requires_explicit_cursor_request
```

- [ ] **Step 2: Run the suite and verify the new contract fails**

Run:

```bash
bash tests/review_test.sh
```

Expected: existing 11 tests pass and the new explicit-trigger test fails against
the broad automatic metadata.

- [ ] **Step 3: Replace broad metadata and iterative workflow**

Use this frontmatter:

```yaml
---
name: cursor-code-review
description: Use only when the user explicitly requests Cursor review, asks to review through Cursor, says "проверь через Cursor" or "запусти Cursor review", or invokes $cursor-code-review or /cursor-code-review. Do not use for generic implementation, completion, verification, or code-review requests that do not name Cursor.
compatibility: Requires Bash, Git, awk, jq, network access, and an authenticated Cursor Agent CLI available as agent.
---
```

Replace the workflow with one run:

```markdown
## Required Workflow

1. Confirm the user explicitly requested Cursor review.
2. Run relevant local verification when available.
3. Resolve `scripts/review.sh` relative to this `SKILL.md`.
4. From inside the changed Git worktree, run `scripts/review.sh` exactly once:

   ```bash
   <skill-directory>/scripts/review.sh \
     "<task summary and acceptance criteria>" \
     "<verification performed>"
   ```

5. Validate and report the result. Do not automatically fix and re-review.
6. A new explicit user request is required for another review.
```

Keep the existing recursion, read-only, mutation, and verdict guidance. Remove
the three-cycle instructions and red flags about completing without review.

- [ ] **Step 4: Run tests and skill validation**

Run:

```bash
bash tests/review_test.sh
uv run --with pyyaml python \
  /Users/h0b0/.agents/skills/skill-creator/scripts/quick_validate.py \
  /Users/h0b0/Documents/private/cursor-code-review-skill
```

Expected: 12 tests pass and validator prints `Skill is valid!`.

### Task 2: Heartbeat and hard timeout

**Files:**
- Modify: `scripts/review.sh`
- Modify: `tests/review_test.sh`

**Interfaces:**
- Consumes: optional positive integers `CURSOR_REVIEW_TIMEOUT_SECONDS` and `CURSOR_REVIEW_HEARTBEAT_SECONDS`.
- Produces: default 600-second deadline, default 30-second heartbeat, exit `2` on timeout, and the existing PASS/FAIL/protocol contract on normal completion.

- [ ] **Step 1: Extend the fake agent and cleanup**

Add `AGENT_SLEEP_SECONDS` to cleanup and make the fake agent sleep before
printing its result:

```bash
unset AGENT_ARGS_FILE AGENT_ENV_FILE AGENT_MUTATE_PATH AGENT_SLEEP_SECONDS

# In the fake agent body, before AGENT_OUTPUT:
sleep "${AGENT_SLEEP_SECONDS:-0}"
```

- [ ] **Step 2: Add failing timeout tests**

Add:

```bash
test_invalid_timeout_is_rejected() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_TIMEOUT_SECONDS=0 PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && ! -e "$FIXTURE/args" ]]
}

test_hung_agent_times_out_with_heartbeat() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_SLEEP_SECONDS=5
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS"}'

  local output
  output="$(
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_TIMEOUT_SECONDS=1 \
    CURSOR_REVIEW_HEARTBEAT_SECONDS=1 \
    PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change" 2>&1
  )"
  local status=$?

  [[ $status -eq 2 ]] &&
    [[ "$output" == *"review still running"* ]] &&
    [[ "$output" == *"timed out after 1 seconds"* ]]
}

run_test "non-positive timeout is rejected before agent runs" \
  test_invalid_timeout_is_rejected
run_test "hung agent emits heartbeat and times out" \
  test_hung_agent_times_out_with_heartbeat
```

- [ ] **Step 3: Run tests and verify the timeout behaviors fail**

Run:

```bash
bash tests/review_test.sh
```

Expected: the explicit-trigger contract remains green; timeout validation and
hung-agent tests fail because the runner still waits indefinitely.

- [ ] **Step 4: Implement background execution, heartbeat, and timeout**

In `scripts/review.sh`:

1. Read defaults:

   ```bash
   timeout_seconds="${CURSOR_REVIEW_TIMEOUT_SECONDS:-600}"
   heartbeat_seconds="${CURSOR_REVIEW_HEARTBEAT_SECONDS:-30}"
   ```

2. Reject values that do not match `^[1-9][0-9]*$`.
3. Create temporary stdout, stderr, and timeout-marker paths.
4. Start the existing `agent` invocation in the background with stdout and
   stderr redirected to the temporary files.
5. Start a monitor subshell that:
   - sleeps for at most the heartbeat interval;
   - prints `cursor-code-review: review still running (<elapsed>s)` every
     heartbeat;
   - at the deadline, creates the marker, sends `TERM`, waits five seconds, and
     sends `KILL` if the agent remains alive.
6. Wait for `agent`, stop and reap the monitor, then read stdout.
7. Run the existing after-fingerprint check.
8. If the timeout marker exists, print Cursor stderr, report
   `timed out after <N> seconds`, and exit `2`.
9. Otherwise continue through the existing agent-status, JSON, and verdict
   handling.

The EXIT/INT/TERM/HUP cleanup trap must stop both background PIDs and delete all
temporary files, preventing orphan processes.

- [ ] **Step 5: Run the full deterministic suite**

Run:

```bash
bash tests/review_test.sh
bash -n scripts/review.sh tests/review_test.sh
git diff --check
```

Expected: 14 tests pass; syntax and whitespace checks exit `0`.

### Task 3: Documentation, validation, and PR update

**Files:**
- Modify: `docs/superpowers/specs/2026-07-29-cursor-code-review-skill-design.md`
- Create: `docs/superpowers/specs/2026-07-29-explicit-trigger-and-timeout-design.md`
- Create: `docs/superpowers/plans/2026-07-29-explicit-trigger-and-timeout.md`

**Interfaces:**
- Consumes: completed behavior from Tasks 1–2.
- Produces: accurate design history, clean committed branch, and updated remote draft PR.

- [ ] **Step 1: Update the original design's superseded requirements**

Add a note that the explicit-trigger spec supersedes automatic invocation,
three-cycle retry, and unbounded execution. Do not rewrite history or delete the
original rationale.

- [ ] **Step 2: Run fresh final verification**

Run:

```bash
bash tests/review_test.sh
bash -n scripts/review.sh tests/review_test.sh
uv run --with pyyaml python \
  /Users/h0b0/.agents/skills/skill-creator/scripts/quick_validate.py \
  /Users/h0b0/Documents/private/cursor-code-review-skill
git diff --check
test "$(readlink "$HOME/.agents/skills/cursor-code-review")" = \
  "/Users/h0b0/Documents/private/cursor-code-review-skill"
```

Expected: 14 tests pass, validator passes, syntax and diff checks pass, symlink
still resolves to the source repository.

- [ ] **Step 3: Commit the implementation**

```bash
git add SKILL.md scripts/review.sh tests/review_test.sh \
  docs/superpowers/specs/2026-07-29-cursor-code-review-skill-design.md \
  docs/superpowers/specs/2026-07-29-explicit-trigger-and-timeout-design.md \
  docs/superpowers/plans/2026-07-29-explicit-trigger-and-timeout.md
git commit -m "fix: make Cursor review explicit and bounded"
```

- [ ] **Step 4: Push the existing feature branch**

```bash
git push origin feature/cursor-code-review-skill
```

Expected: existing draft PR #1 updates to the new head commit.

- [ ] **Step 5: Verify PR state**

```bash
gh pr view 1 --json url,isDraft,state,mergeable,mergeStateStatus,statusCheckRollup
git status -sb
```

Expected: PR remains open and draft; local branch tracks origin with a clean
worktree.
