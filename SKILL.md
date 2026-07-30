---
name: cursor-code-review
description: Use only when the user explicitly requests Cursor review, asks to review through Cursor, says "проверь через Cursor" or "запусти Cursor review", or invokes $cursor-code-review or /cursor-code-review. Do not use for generic implementation, completion, verification, or code-review requests that do not name Cursor.
compatibility: Requires Bash, Git, awk, jq, network access, and an authenticated Cursor Agent CLI available as agent.
---

# Cursor Code Review

Run an independent Cursor review only when the user explicitly requests it.
Cursor supplies evidence; the calling agent remains responsible for deciding
whether each finding is valid.

## Recursion Guard

If `CURSOR_REVIEW_ACTIVE` is non-empty, stop. A nested Cursor reviewer must not
start another review.

## Required Workflow

1. Confirm the user explicitly requested Cursor review.
2. Run relevant local verification when available.
3. Resolve `scripts/review.sh` relative to this `SKILL.md`.
4. From inside the changed Git worktree: Run `scripts/review.sh` exactly once.

   ```bash
   <skill-directory>/scripts/review.sh \
     "<task summary and acceptance criteria>" \
     "<verification performed>"
   ```

5. Handle the exit code:

   | Exit | Meaning | Action |
   |---|---|---|
   | `0` | Review passed | Report external review passed. |
   | `1` | Findings | Validate each finding; fix only technically valid ones. |
   | `2` | Review failed | Report the operational failure; never call failure approval. |

6. Validate and report the result. Do not automatically fix and re-review.
7. A new explicit user request is required for another review.

## Review Discipline

- Keep Cursor read-only. Never add `--force`, `--yolo`, or a write-capable mode.
- The runner fingerprints Git-visible worktree state and turns any persistent
  reviewer mutation into exit `2`; inspect such changes instead of trusting the
  verdict.
- The runner emits a heartbeat every 30 seconds and stops Cursor after 10
  minutes by default. A timeout is exit `2`, not approval.
- Reject stylistic preferences and speculative refactors outside task scope.
- Include final Cursor verdict and unresolved validated findings in handoff.

## Red Flags

- Treating every model comment as correct.
- Treating exit `2` as PASS.
- Running another review without a new explicit user request.
