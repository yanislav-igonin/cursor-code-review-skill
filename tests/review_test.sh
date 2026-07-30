#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

cleanup_fixture() {
  if [[ -n "${FIXTURE:-}" && -d "$FIXTURE" ]]; then
    rm -rf "$FIXTURE"
  fi
  unset AGENT_ARGS_FILE AGENT_CHILD_PID_FILE AGENT_ENV_FILE
  unset AGENT_MUTATE_PATH AGENT_ORPHAN_PID_FILE
  unset AGENT_ORPHAN_WRITER_SECONDS AGENT_SLEEP_SECONDS
  unset AGENT_EARLY_OUTPUT AGENT_OUTPUT AGENT_STDERR AGENT_EXIT
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
    'if [[ -n "${AGENT_EARLY_OUTPUT:-}" ]]; then printf "%s\n" "$AGENT_EARLY_OUTPUT"; fi' \
    'if [[ -n "${AGENT_CHILD_PID_FILE:-}" ]]; then' \
    '  sleep "${AGENT_SLEEP_SECONDS:-0}" &' \
    '  child_pid=$!' \
    '  printf "%s\n" "$child_pid" >"$AGENT_CHILD_PID_FILE"' \
    '  wait "$child_pid"' \
    'else' \
    '  sleep "${AGENT_SLEEP_SECONDS:-0}"' \
    'fi' \
    'if [[ -n "${AGENT_ORPHAN_WRITER_SECONDS:-}" ]]; then' \
    '  sleep "$AGENT_ORPHAN_WRITER_SECONDS" &' \
    '  printf "%s\n" "$!" >"$AGENT_ORPHAN_PID_FILE"' \
    'fi' \
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
    grep -Fqx -- '--output-format=stream-json' "$FIXTURE/args" &&
    ! grep -Fqx -- '--stream-partial-output' "$FIXTURE/args" &&
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
    grep -Fq -- 'sanitized progress' "$skill" &&
    grep -Fq -- 'last Cursor event' "$skill" &&
    grep -Fq -- 'does not expose assistant text or tool content' "$skill" &&
    grep -Fq -- 'Stream idleness alone does not stop the review' "$skill" &&
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

test_leading_zero_timeout_is_rejected() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_TIMEOUT_SECONDS=08 PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 && ! -e "$FIXTURE/args" ]]
}

test_leading_zero_heartbeat_is_rejected() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_HEARTBEAT_SECONDS=00 PATH="$FIXTURE/bin:$PATH" \
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
    [[ "$output" == *"last Cursor event "*"s ago"* ]] &&
    [[ "$output" == *"timed out after 1 seconds"* ]]
}

test_timeout_terminates_agent_child() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_CHILD_PID_FILE="$FIXTURE/child-pid"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_SLEEP_SECONDS=30

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_TIMEOUT_SECONDS=1 \
    CURSOR_REVIEW_HEARTBEAT_SECONDS=1 \
    PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  local status=$?
  local child_pid
  child_pid="$(<"$AGENT_CHILD_PID_FILE")"

  [[ $status -eq 2 && -n "$child_pid" ]] &&
    ! kill -0 "$child_pid" 2>/dev/null
}

test_agent_exit_with_open_fifo_is_bounded() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_ORPHAN_PID_FILE="$FIXTURE/orphan-pid"
  export AGENT_ORPHAN_WRITER_SECONDS=10
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS"}'

  (
    cd "$FIXTURE/repo" || exit 1
    CURSOR_REVIEW_TIMEOUT_SECONDS=1 \
    CURSOR_REVIEW_HEARTBEAT_SECONDS=1 \
    PATH="$FIXTURE/bin:$PATH" \
      "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1 &
  local runner_pid=$!
  local finished=0
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if ! kill -0 "$runner_pid" 2>/dev/null; then
      finished=1
      break
    fi
    sleep 0.1
  done
  if [[ "$finished" -eq 0 ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
  fi
  wait "$runner_pid"
  local status=$?
  local orphan_pid
  orphan_pid="$(<"$AGENT_ORPHAN_PID_FILE")"

  [[ $finished -eq 1 && $status -eq 2 && -n "$orphan_pid" ]] &&
    ! kill -0 "$orphan_pid" 2>/dev/null
}

test_runner_fails_closed_when_job_control_cannot_start() {
  grep -Fq -- 'set -m || die "could not enable job control for bounded review"' \
    "$ROOT/scripts/review.sh"
}

test_missing_terminal_result_is_protocol_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"system","subtype":"init"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_duplicate_terminal_events_are_protocol_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT=$'{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS"}\n{"type":"result","subtype":"error","is_error":true,"result":"late failure"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_unsuccessful_terminal_event_is_protocol_failure() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_OUTPUT='{"type":"result","subtype":"error","is_error":true,"result":"VERDICT: PASS"}'

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

test_stream_progress_is_early_and_sanitized() {
  make_fixture
  export AGENT_ARGS_FILE="$FIXTURE/args"
  export AGENT_ENV_FILE="$FIXTURE/env"
  export AGENT_SLEEP_SECONDS=1
  export AGENT_EARLY_OUTPUT=$'{"type":"system","subtype":"init","apiKeySource":"SECRET_API_SOURCE"}\n{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"/SECRET/PATH"}}}}\n{"type":"assistant","message":{"content":[{"type":"text","text":"SECRET_ASSISTANT"}]}}\n{"type":"tool_call","subtype":"completed","tool_call":{"completedAtMs":123,"readToolCall":{"result":{"success":{"content":"SECRET_TOOL_RESULT"}}}}}\n{"type":"connection","subtype":"reconnecting","detail":"SECRET_CONNECTION"}\n{"type":"retry","subtype":"starting","detail":"SECRET_RETRY"}\n{"type":"future","payload":"SECRET_UNKNOWN"}'
  export AGENT_OUTPUT='{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS"}'
  local stdout_file="$FIXTURE/stdout"
  local stderr_file="$FIXTURE/stderr"

  (
    cd "$FIXTURE/repo" || exit 1
    PATH="$FIXTURE/bin:$PATH" "$ROOT/scripts/review.sh" "Change"
  ) >"$stdout_file" 2>"$stderr_file" &
  local runner_pid=$!
  local progress_seen=0
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if grep -Fq -- 'Cursor tool completed: readToolCall' "$stderr_file" 2>/dev/null; then
      progress_seen=1
      break
    fi
    sleep 0.05
  done
  local was_running=0
  kill -0 "$runner_pid" 2>/dev/null && was_running=1
  wait "$runner_pid"
  local status=$?
  local progress
  progress="$(<"$stderr_file")"
  local final_output
  final_output="$(<"$stdout_file")"

  [[ $status -eq 0 && $progress_seen -eq 1 && $was_running -eq 1 ]] &&
    [[ "$final_output" == "VERDICT: PASS" ]] &&
    [[ "$progress" == *"Cursor session started"* ]] &&
    [[ "$progress" == *"Cursor tool started: readToolCall"* ]] &&
    [[ "$progress" == *"Cursor tool completed: readToolCall"* ]] &&
    [[ "$progress" == *"Cursor connection reconnecting"* ]] &&
    [[ "$progress" == *"Cursor retry starting"* ]] &&
    [[ "$progress" != *"SECRET_API_SOURCE"* ]] &&
    [[ "$progress" != *"SECRET_ASSISTANT"* ]] &&
    [[ "$progress" != *"SECRET_TOOL_RESULT"* ]] &&
    [[ "$progress" != *"SECRET_CONNECTION"* ]] &&
    [[ "$progress" != *"SECRET_RETRY"* ]] &&
    [[ "$progress" != *"SECRET_UNKNOWN"* ]] &&
    [[ "$progress" != *"/SECRET/PATH"* ]]
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
run_test "leading-zero timeout is rejected before agent runs" \
  test_leading_zero_timeout_is_rejected
run_test "leading-zero heartbeat is rejected before agent runs" \
  test_leading_zero_heartbeat_is_rejected
run_test "hung agent emits heartbeat and times out" \
  test_hung_agent_times_out_with_heartbeat
run_test "timeout terminates the agent child process" \
  test_timeout_terminates_agent_child
run_test "agent exit with inherited FIFO writer remains bounded" \
  test_agent_exit_with_open_fifo_is_bounded
run_test "runner fails closed if job control cannot start" \
  test_runner_fails_closed_when_job_control_cannot_start
run_test "missing terminal result is rejected" \
  test_missing_terminal_result_is_protocol_failure
run_test "duplicate terminal events are rejected" \
  test_duplicate_terminal_events_are_protocol_failure
run_test "unsuccessful terminal event is rejected" \
  test_unsuccessful_terminal_event_is_protocol_failure
run_test "stream progress is visible early and sanitized" \
  test_stream_progress_is_early_and_sanitized

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
