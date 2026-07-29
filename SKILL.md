---
name: cursor-code-review
description: Use when an implementation task changed code, tests, configuration, build scripts, generated artifacts, or executable behavior and local verification is complete, before claiming the task is finished.
compatibility: Requires Bash, Git, jq, network access, and an authenticated Cursor Agent CLI available as agent.
---

# Cursor Code Review

Require an independent Cursor review after local verification. Cursor supplies
evidence; the calling agent remains responsible for deciding whether each
finding is valid.

## Recursion Guard

If `CURSOR_REVIEW_ACTIVE` is non-empty, stop. A nested Cursor reviewer must not
start another review.

## Required Workflow

1. Finish implementation and run the project's normal verification.
2. Resolve `scripts/review.sh` relative to this `SKILL.md`, not the project.
3. From inside the changed Git worktree, run:

   ```bash
   <skill-directory>/scripts/review.sh \
     "<task summary and acceptance criteria>" \
     "<tests, type checks, lint, or other verification performed>"
   ```

4. Handle the exit code:

   | Exit | Meaning | Action |
   |---|---|---|
   | `0` | Review passed | Report external review passed. |
   | `1` | Findings | Validate each finding; fix only technically valid ones. |
   | `2` | Review failed | Retry transient failures; never call failure approval. |

5. After valid fixes, rerun local verification, then Cursor review.
6. Use a maximum of three review cycles total.
7. Report unresolved findings or unavailable review explicitly. Do not claim a
   clean external review.

## Review Discipline

- Keep Cursor read-only. Never add `--force`, `--yolo`, or a write-capable mode.
- Reject stylistic preferences and speculative refactors outside task scope.
- Include final Cursor verdict and unresolved validated findings in handoff.

## Red Flags

- Claiming completion before invoking the script.
- Treating every model comment as correct.
- Treating exit `2` as PASS.
- Starting a fourth review cycle.
