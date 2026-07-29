# Cursor Code Review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install a shared Agent Skill that runs an independent, read-only Cursor Grok 4.5 High review after implementation tasks and guides the caller through at most three fix-and-review cycles.

**Architecture:** `SKILL.md` owns trigger semantics and the review/fix/re-review workflow. A single Bash boundary script validates its environment, fingerprints Git-visible worktree state, invokes Cursor Agent in sandboxed Ask mode, extracts the JSON result with `jq`, and maps the final verdict to stable exit codes. Shell tests replace `agent` with a fake executable so command construction and failure behavior are verified without spending model tokens.

**Tech Stack:** Agent Skills open format, Bash 3.2+, Git CLI, Cursor Agent CLI, `jq` 1.6+

## Global Constraints

- Source of truth: `/Users/h0b0/Documents/private/cursor-code-review-skill`.
- Install with symlink `~/.agents/skills/cursor-code-review` pointing to the source directory.
- Reviewer model must be exactly `cursor-grok-4.5-high`, never a Fast variant.
- Cursor review must use `--mode=ask` and must never use `--force` or `--yolo`.
- Cursor review must use `--sandbox=enabled`; persistent Git-visible reviewer mutations must return exit `2`.
- Review up to three total cycles; never treat operational failure as approval.
- Do not invoke review when `CURSOR_REVIEW_ACTIVE` is already set.
- Production implementation stays within `SKILL.md` and `scripts/review.sh`.

---

### Task 1: Read-only Cursor review boundary

**Files:**
- Create: `scripts/review.sh`
- Create: `tests/review_test.sh`

**Interfaces:**
- Consumes: `agent`, `git`, and `jq` executables from `PATH`; positional arguments `TASK_SUMMARY` and optional `VERIFICATION_EVIDENCE`.
- Produces: human-readable review on stdout; exit `0` for `VERDICT: PASS`, exit `1` for `VERDICT: FAIL`, and exit `2` for recursion, preflight, CLI, JSON, or protocol errors.

- [ ] **Step 1: Write the shell test harness and failing PASS-path test**

Create `tests/review_test.sh` with:

```bash
#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

make_fixture() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/bin" "$FIXTURE/repo/nested"
  git -C "$FIXTURE/repo" init -q
  git -C "$FIXTURE/repo" config user.email test@example.com
  git -C "$FIXTURE/repo" config user.name Test
  printf 'base\n' >"$FIXTURE/repo/tracked.txt"
  git -C "$FIXTURE/repo" add tracked.txt
  git -C "$FIXTURE/repo" commit -qm base
  printf 'changed\n' >"$FIXTURE/repo/tracked.txt"
}

write_fake_agent() {
  cat >"$FIXTURE/bin/agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$AGENT_ARGS_FILE"
printf '%s\n' "${AGENT_STDERR:-}" >&2
printf '%s\n' "${AGENT_OUTPUT:-}"
exit "${AGENT_EXIT:-0}"
AGENT
  chmod +x "$FIXTURE/bin/agent"
}

test_pass_and_command_contract() {
  make_fixture
  write_fake_agent
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"No actionable findings.\nVERDICT: PASS"}'

  (
    cd "$FIXTURE/repo/nested" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" \
      "Implement tracked change" "tests passed"
  )
  local status=$?

  [[ $status -eq 0 ]] &&
    grep -Fx -- '--mode=ask' "$FIXTURE/args" &&
    grep -Fx -- 'cursor-grok-4.5-high' "$FIXTURE/args" &&
    grep -Fx -- "$FIXTURE/repo" "$FIXTURE/args" &&
    ! grep -Fx -- '--force' "$FIXTURE/args" &&
    ! grep -Fx -- '--yolo' "$FIXTURE/args" &&
    grep -Fq -- 'Implement tracked change' "$FIXTURE/args" &&
    grep -Fq -- 'tests passed' "$FIXTURE/args"
  local result=$?
  rm -rf "$FIXTURE"
  return $result
}

run_test "PASS maps to exit 0 and safe command" test_pass_and_command_contract

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/review_test.sh
```

Expected: FAIL because `scripts/review.sh` does not exist.

- [ ] **Step 3: Implement the minimal PASS path**

Create executable `scripts/review.sh`:

```bash
#!/usr/bin/env bash
set -u

die() {
  printf 'cursor-code-review: %s\n' "$*" >&2
  exit 2
}

[[ -z "${CURSOR_REVIEW_ACTIVE:-}" ]] ||
  die "refusing recursive review: CURSOR_REVIEW_ACTIVE is set"
command -v agent >/dev/null 2>&1 || die "'agent' is not installed or not on PATH"
command -v jq >/dev/null 2>&1 || die "'jq' is not installed or not on PATH"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "current directory is not inside a Git worktree"
task_summary="${1:-}"
verification="${2:-Not provided}"
[[ -n "$task_summary" ]] || die "usage: review.sh TASK_SUMMARY [VERIFICATION_EVIDENCE]"

prompt="$(printf '%s\n' \
  'Act as an independent code reviewer. Do not modify files or run destructive commands.' \
  "Task: $task_summary" \
  "Verification evidence: $verification" \
  'Inspect git status, staged and unstaged changes, relevant untracked files, and nearby code.' \
  'Report only evidenced correctness, regression, security, data-integrity, requirement, or material test-gap findings.' \
  'Omit style preferences and speculative refactors.' \
  'For each finding include severity, file:line when applicable, evidence, and the smallest practical fix.' \
  'End with exactly VERDICT: PASS when there are no actionable findings, otherwise VERDICT: FAIL.')"

stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

output="$(
  CURSOR_REVIEW_ACTIVE=1 agent -p \
    --mode=ask \
    --trust \
    --model cursor-grok-4.5-high \
    --output-format=json \
    --workspace "$repo_root" \
    "$prompt" 2>"$stderr_file"
)"
agent_status=$?
if [[ $agent_status -ne 0 ]]; then
  cat "$stderr_file" >&2
  die "Cursor Agent failed with exit $agent_status"
fi

result="$(printf '%s' "$output" | jq -er \
  'select(.type == "result" and .subtype == "success" and .is_error == false) | .result | strings' \
  2>/dev/null)" || die "Cursor Agent returned malformed or unsuccessful JSON"

printf '%s\n' "$result"
case "$result" in
  *"VERDICT: PASS") exit 0 ;;
  *"VERDICT: FAIL") exit 1 ;;
  *) die "Cursor review omitted a valid final verdict" ;;
esac
```

Make both scripts executable:

```bash
chmod +x scripts/review.sh tests/review_test.sh
```

- [ ] **Step 4: Run the PASS-path test**

Run:

```bash
bash tests/review_test.sh
```

Expected: `1 passed, 0 failed`.

- [ ] **Step 5: Add FAIL and operational-error tests**

Append test functions before the `run_test` calls in `tests/review_test.sh` and register each with `run_test`:

```bash
test_fail_verdict() {
  make_fixture
  write_fake_agent
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"[high] tracked.txt:1 regression\nVERDICT: FAIL"}'
  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change" "verified"
  )
  [[ $? -eq 1 ]]
  local result=$?
  rm -rf "$FIXTURE"
  return $result
}

test_malformed_json() {
  make_fixture
  write_fake_agent
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_OUTPUT='not-json'
  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
  local result=$?
  rm -rf "$FIXTURE"
  return $result
}

test_agent_failure() {
  make_fixture
  write_fake_agent
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_OUTPUT=''
  export AGENT_STDERR='authentication failed'
  export AGENT_EXIT=17
  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  local status=$?
  unset AGENT_EXIT AGENT_STDERR
  rm -rf "$FIXTURE"
  [[ $status -eq 2 ]]
}

test_recursion_guard() {
  make_fixture
  write_fake_agent
  export AGENT_ARGS_FILE="$FIXTURE/args"
  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_ACTIVE=1 PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  local status=$?
  rm -rf "$FIXTURE"
  [[ $status -eq 2 ]]
}
```

Expected registrations:

```bash
run_test "PASS maps to exit 0 and safe command" test_pass_and_command_contract
run_test "FAIL maps to exit 1" test_fail_verdict
run_test "malformed JSON maps to exit 2" test_malformed_json
run_test "agent failure maps to exit 2" test_agent_failure
run_test "recursive review maps to exit 2" test_recursion_guard
```

- [ ] **Step 6: Run all boundary tests**

Run:

```bash
bash tests/review_test.sh
```

Expected: `5 passed, 0 failed`.

- [ ] **Step 7: Commit the boundary**

```bash
git add scripts/review.sh tests/review_test.sh
git commit -m "feat: add read-only Cursor review runner"
```

### Task 2: Agent Skill workflow

**Files:**
- Create: `SKILL.md`
- Modify: `tests/review_test.sh`

**Interfaces:**
- Consumes: `scripts/review.sh TASK_SUMMARY [VERIFICATION_EVIDENCE]` and its exit-code contract from Task 1.
- Produces: discoverable `cursor-code-review` skill instructions requiring review before completion, independent validation of findings, and at most three total cycles.

- [ ] **Step 1: Add failing static contract tests**

Add a `test_skill_contract` function to `tests/review_test.sh`:

```bash
test_skill_contract() {
  local skill="$ROOT/SKILL.md"
  [[ -f "$skill" ]] &&
    grep -Fq -- 'name: cursor-code-review' "$skill" &&
    grep -Fq -- 'must use' "$skill" &&
    grep -Fq -- 'CURSOR_REVIEW_ACTIVE' "$skill" &&
    grep -Fq -- 'maximum of three review cycles' "$skill" &&
    grep -Fq -- 'scripts/review.sh' "$skill" &&
    grep -Fq -- 'Exit 0' "$skill" &&
    grep -Fq -- 'Exit 1' "$skill" &&
    grep -Fq -- 'Exit 2' "$skill"
}
```

Register it:

```bash
run_test "SKILL.md defines mandatory bounded workflow" test_skill_contract
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/review_test.sh
```

Expected: `SKILL.md defines mandatory bounded workflow` fails because `SKILL.md` is absent.

- [ ] **Step 3: Create the skill instructions**

Create `SKILL.md` with valid frontmatter:

```markdown
---
name: cursor-code-review
description: Must use after completing any task that changes code, tests, configuration, build scripts, or executable behavior, before claiming completion. Runs an independent read-only review through Cursor Agent and requires validated findings to be fixed and re-reviewed.
---

# Cursor Code Review

Run independent Cursor review after local verification and before claiming the
implementation is complete.

## Recursion Guard

If `CURSOR_REVIEW_ACTIVE` is non-empty, stop. Do not invoke this skill from the
nested Cursor reviewer.

## Required Workflow

1. Finish implementation and run the project's normal verification.
2. Summarize the task and verification evidence concisely.
3. From inside the changed Git worktree, run:

   ```bash
   "<skill-directory>/scripts/review.sh" \
     "<task summary and acceptance criteria>" \
     "<tests, type checks, lint, or other verification performed>"
   ```

4. Interpret the result:
   - Exit 0: Cursor found no actionable issues. Report external review passed.
   - Exit 1: Validate every finding against the code. Fix only technically valid
     findings; do not accept feedback performatively.
   - Exit 2: Review infrastructure failed. Retry transient failures when useful.
     Never describe an operational failure as approval.
5. After valid fixes, rerun local verification, then rerun Cursor review.
6. Use a maximum of three review cycles total.
7. If findings remain after cycle three, or review cannot run, report that
   explicitly and do not claim a clean external review.

## Review Discipline

- Cursor is a reviewer, not an editor. Never add `--force`, `--yolo`, or replace
  Ask mode with a write-capable mode.
- Treat review output as evidence to examine, not authority.
- Do not fix stylistic preferences or speculative refactors outside task scope.
- Include the final Cursor verdict and unresolved validated findings in handoff.
```

- [ ] **Step 4: Run all tests and validate the skill**

Run:

```bash
bash tests/review_test.sh
```

Expected: `6 passed, 0 failed`.

If the installed skill-creator package provides a validator, run that validator
against the repository root and require exit `0`. Otherwise verify YAML
frontmatter contains non-empty `name` and `description` and the directory
contains `SKILL.md`.

- [ ] **Step 5: Commit the skill workflow**

```bash
git add SKILL.md tests/review_test.sh
git commit -m "feat: define mandatory Cursor review workflow"
```

### Task 3: Shared installation and live smoke test

**Files:**
- Create symlink: `~/.agents/skills/cursor-code-review`
- Modify only if live review finds a valid issue: `SKILL.md`, `scripts/review.sh`, or `tests/review_test.sh`

**Interfaces:**
- Consumes: completed skill repository and authenticated `agent` CLI.
- Produces: globally discoverable skill and evidence that real Cursor Grok 4.5 High can review it read-only.

- [ ] **Step 1: Verify the intended install target**

Run:

```bash
test ! -e "$HOME/.agents/skills/cursor-code-review" &&
test ! -L "$HOME/.agents/skills/cursor-code-review"
```

Expected: exit `0`. If a target exists, inspect it and preserve it rather than
overwriting it.

- [ ] **Step 2: Install the source with one symlink**

Run:

```bash
ln -s /Users/h0b0/Documents/private/cursor-code-review-skill \
  "$HOME/.agents/skills/cursor-code-review"
```

Verify:

```bash
test "$(readlink "$HOME/.agents/skills/cursor-code-review")" = \
  "/Users/h0b0/Documents/private/cursor-code-review-skill"
```

Expected: exit `0`.

- [ ] **Step 3: Run deterministic verification**

Run:

```bash
bash tests/review_test.sh
git status -sb
```

Expected: all tests pass; only the implementation-plan document may remain
uncommitted before its documentation commit.

- [ ] **Step 4: Run one live external review**

From the repository root, run:

```bash
scripts/review.sh \
  "Implement shared cursor-code-review Agent Skill according to the approved design spec" \
  "bash tests/review_test.sh: all tests passed"
```

Expected: Cursor CLI reports model `cursor-grok-4.5-high` internally, performs a
read-only review, returns valid JSON through the wrapper, and ends with
`VERDICT: PASS` or actionable `VERDICT: FAIL`.

- [ ] **Step 5: Resolve valid findings with bounded cycles**

For `VERDICT: FAIL`, inspect each finding. For valid findings:

1. Add or update a regression test in `tests/review_test.sh`.
2. Run it and verify the new assertion fails.
3. Make the smallest change in `scripts/review.sh` or `SKILL.md`.
4. Run `bash tests/review_test.sh` and require all tests pass.
5. Re-run `scripts/review.sh` with updated verification evidence.

Stop after at most three total live reviews. Do not change code for unsupported
or stylistic findings.

- [ ] **Step 6: Commit documentation and any review-driven fixes**

```bash
git add docs/superpowers/plans/2026-07-29-cursor-code-review-skill.md \
  SKILL.md scripts/review.sh tests/review_test.sh
git commit -m "docs: add Cursor review skill implementation plan"
```

If review-driven changes were required, commit them separately before the plan:

```bash
git commit -m "fix: address external review findings"
```

- [ ] **Step 7: Final verification**

Run:

```bash
bash tests/review_test.sh
git status -sb
git log --oneline --decorate -5
```

Expected: tests pass, worktree is clean, and history contains the design,
implementation, skill workflow, and plan commits.
