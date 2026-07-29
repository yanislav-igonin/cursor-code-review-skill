#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

cleanup_fixture() {
  if [[ -n "${FIXTURE:-}" && -d "$FIXTURE" ]]; then
    rm -rf "$FIXTURE"
  fi
  unset AGENT_ARGS_FILE AGENT_ENV_FILE AGENT_MUTATE_PATH AGENT_SLEEP_SECONDS
  unset AGENT_OUTPUT AGENT_STDERR AGENT_EXIT
}

run_test() {
  local name="$1"
  shift

  FIXTURE=""
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$name"
  fi
  cleanup_fixture
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

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" >"$AGENT_ARGS_FILE"' \
    'printf "%s\n" "${CURSOR_REVIEW_ACTIVE:-}" >"$AGENT_ENV_FILE"' \
    'if [[ -n "${AGENT_MUTATE_PATH:-}" ]]; then printf "mutated\n" >"$AGENT_MUTATE_PATH"; fi' \
    'sleep "${AGENT_SLEEP_SECONDS:-0}"' \
    'printf "%s\n" "${AGENT_STDERR:-}" >&2' \
    'printf "%s\n" "${AGENT_OUTPUT:-}"' \
    'exit "${AGENT_EXIT:-0}"' \
    >"$FIXTURE/bin/agent"
  chmod +x "$FIXTURE/bin/agent"
}

test_pass_and_command_contract() {
  make_fixture
  local expected_root
  expected_root="$(git -C "$FIXTURE/repo" rev-parse --show-toplevel)"
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"No actionable findings.\nVERDICT: PASS"}'

  (
    cd "$FIXTURE/repo/nested" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" \
      "Implement tracked change" "tests passed"
  )
  local status=$?

  [[ $status -eq 0 ]] &&
    grep -Fqx -- '-p' "$FIXTURE/args" &&
    grep -Fqx -- '--mode=ask' "$FIXTURE/args" &&
    grep -Fqx -- '--trust' "$FIXTURE/args" &&
    grep -Fqx -- '--sandbox=enabled' "$FIXTURE/args" &&
    grep -Fqx -- '--output-format=json' "$FIXTURE/args" &&
    grep -Fqx -- 'cursor-grok-4.5-high' "$FIXTURE/args" &&
    grep -Fqx -- "$expected_root" "$FIXTURE/args" &&
    ! grep -Fx -- '--force' "$FIXTURE/args" &&
    ! grep -Fx -- '--yolo' "$FIXTURE/args" &&
    grep -Fq -- 'Implement tracked change' "$FIXTURE/args" &&
    grep -Fq -- 'tests passed' "$FIXTURE/args" &&
    grep -Fq -- 'already committed' "$FIXTURE/args" &&
    grep -Fq -- 'critical, high, medium, or low' "$FIXTURE/args" &&
    grep -Fqx -- '1' "$FIXTURE/env"
}

test_fail_verdict() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"[high] tracked.txt:1 regression\nVERDICT: FAIL"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change" "verified"
  ) >/dev/null
  [[ $? -eq 1 ]]
}

test_malformed_json() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='not-json'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_agent_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT=''
  export AGENT_STDERR='authentication failed'
  export AGENT_EXIT=17

  local output
  output="$(
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change" 2>&1
  )"
  local status=$?

  [[ $status -eq 2 ]] &&
    [[ "$output" == *"authentication failed"* ]] &&
    [[ "$output" == *"Cursor Agent failed with exit 17"* ]]
}

test_recursion_guard() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_ACTIVE=1 PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && ! -e "$FIXTURE/args" ]]
}

test_missing_task_summary() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && ! -e "$FIXTURE/args" ]]
}

test_non_git_directory() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && ! -e "$FIXTURE/args" ]]
}

test_post_verdict_harness_text_is_allowed() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS\nAdditional text"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 0 ]]
}

test_embedded_verdict_phrase_is_rejected() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"I cannot give VERDICT: PASS"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_workspace_mutation_is_protocol_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_MUTATE_PATH="$FIXTURE/repo/reviewer-created.txt"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && -f "$AGENT_MUTATE_PATH" ]]
}

test_multiple_verdict_lines_are_protocol_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: FAIL\nCorrection:\nVERDICT: PASS"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_skill_requires_explicit_cursor_request() {
  local skill="$ROOT/SKILL.md"
  local runner="$ROOT/scripts/review.sh"
  grep -Fq -- 'only when the user explicitly requests' "$skill" &&
    grep -Fq -- '$cursor-code-review' "$skill" &&
    grep -Fq -- '/cursor-code-review' "$skill" &&
    grep -Fq -- 'Run `scripts/review.sh` exactly once' "$skill" &&
    grep -Fq -- 'A new explicit user request is required for another review' "$skill" &&
    grep -Fq -- 'heartbeat every 30 seconds' "$skill" &&
    grep -Fq -- 'after 10' "$skill" &&
    grep -Fq -- 'CURSOR_REVIEW_TIMEOUT_SECONDS:-600' "$runner" &&
    grep -Fq -- 'CURSOR_REVIEW_HEARTBEAT_SECONDS:-30' "$runner" &&
    ! grep -Fq -- 'before claiming the task is finished' "$skill" &&
    ! grep -Fq -- 'maximum of three review cycles' "$skill"
}

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

run_test "PASS maps to exit 0 and safe command" test_pass_and_command_contract
run_test "FAIL maps to exit 1" test_fail_verdict
run_test "malformed JSON maps to exit 2" test_malformed_json
run_test "agent failure preserves diagnostics and maps to exit 2" test_agent_failure
run_test "recursive review is rejected before agent runs" test_recursion_guard
run_test "missing task summary is rejected before agent runs" test_missing_task_summary
run_test "non-Git directory is rejected before agent runs" test_non_git_directory
run_test "post-verdict harness text preserves standalone verdict" test_post_verdict_harness_text_is_allowed
run_test "embedded verdict phrase is rejected" test_embedded_verdict_phrase_is_rejected
run_test "workspace mutation converts PASS to protocol failure" test_workspace_mutation_is_protocol_failure
run_test "multiple standalone verdicts are rejected" test_multiple_verdict_lines_are_protocol_failure
run_test "skill requires explicit Cursor request and one review" \
  test_skill_requires_explicit_cursor_request
run_test "non-positive timeout is rejected before agent runs" \
  test_invalid_timeout_is_rejected
run_test "hung agent emits heartbeat and times out" \
  test_hung_agent_times_out_with_heartbeat

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
