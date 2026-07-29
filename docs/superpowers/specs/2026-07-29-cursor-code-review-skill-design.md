# Cursor Code Review Skill Design

## Goal

Create a reusable Agent Skill that requires an independent, read-only review by
Cursor Agent after an agent completes a task that changes code, tests,
configuration, build scripts, or other executable project behavior.

The skill must work from the shared user-level Agent Skills directory so Codex
and other compatible agents can discover it. Cursor Agent is the external
reviewer, using Cursor Grok 4.5 with high reasoning and without Fast mode.

## Installation

The source of truth is:

```text
/Users/h0b0/Documents/private/cursor-code-review-skill
```

The installed skill is a symbolic link:

```text
~/.agents/skills/cursor-code-review
  -> /Users/h0b0/Documents/private/cursor-code-review-skill
```

The skill follows the Agent Skills open format:

```text
cursor-code-review-skill/
├── SKILL.md
├── scripts/
│   └── review.sh
├── tests/
│   └── review_test.sh
└── docs/
    └── superpowers/specs/
        └── 2026-07-29-cursor-code-review-skill-design.md
```

## Trigger and Workflow

The skill description states that agents must use it after completing any task
that changes code, tests, configuration, build scripts, or executable behavior,
and before claiming completion.

The calling agent:

1. Completes the implementation and runs the project's normal verification.
2. Invokes `scripts/review.sh`, passing a concise task summary and verification
   evidence.
3. Independently validates every Cursor finding.
4. Fixes findings that are technically valid.
5. Re-runs project verification and Cursor review.
6. Stops after a clean review or three total review cycles.
7. Reports unresolved findings or review infrastructure failures honestly.

A skill description improves automatic discovery but cannot guarantee invocation
in every agent harness. Vendor-specific global rules may later be added if
absolute enforcement is required.

## Review Command

The script invokes the installed primary Cursor CLI command:

```bash
CURSOR_REVIEW_ACTIVE=1 agent -p \
  --mode=ask \
  --trust \
  --model cursor-grok-4.5-high \
  --output-format=json \
  --workspace <repository-root> \
  <review-prompt>
```

`--mode=ask` keeps the reviewer read-only. The script must not use `--force`,
`--yolo`, or an agent execution mode that permits edits.

`CURSOR_REVIEW_ACTIVE=1` marks the nested review session. The skill must not
invoke another Cursor review when this variable is present, preventing recursive
self-review.

## Review Scope

The prompt tells Cursor to inspect:

- the user task and stated acceptance criteria;
- `git status`;
- staged and unstaged changes;
- relevant untracked files;
- nearby code needed to understand behavior;
- verification evidence supplied by the caller.

The reviewer focuses on:

- correctness defects;
- regressions and missed edge cases;
- security or data-integrity problems;
- violations of explicit task requirements;
- missing tests when they leave changed behavior materially unverified.

It must omit stylistic preferences, speculative refactors, and findings without
specific evidence.

Each finding contains:

- severity: `critical`, `high`, `medium`, or `low`;
- file and line when applicable;
- concise problem statement;
- evidence or reproduction reasoning;
- smallest practical fix.

The final response ends with exactly one verdict marker:

```text
VERDICT: PASS
```

or:

```text
VERDICT: FAIL
```

## Script Interface and Results

The script runs from any path inside a Git worktree and resolves the repository
root itself. It accepts a task summary and optional verification evidence as
arguments without writing temporary project files.

It validates:

- execution is not already inside `CURSOR_REVIEW_ACTIVE`;
- `agent` is installed;
- the current directory belongs to a Git worktree;
- Cursor returns successful JSON;
- the JSON contains a textual result;
- the result ends in a recognized verdict marker.

It prints the human-readable review result to standard output and uses:

- exit `0`: clean review (`VERDICT: PASS`);
- exit `1`: actionable findings (`VERDICT: FAIL`);
- exit `2`: preflight, Cursor CLI, JSON, or protocol failure.

Operational failure never counts as a clean review.

## Error Handling

Authentication, network, timeout, malformed output, and missing CLI errors are
reported with actionable diagnostics. The script preserves Cursor's useful
standard error without exposing credentials.

The calling agent may retry transient operational failures. If review remains
unavailable, it reports that external review did not complete and does not claim
that Cursor approved the change.

## Testing

Shell tests use a temporary Git repository and a fake `agent` executable placed
first on `PATH`. They verify:

- the exact non-Fast model ID `cursor-grok-4.5-high`;
- read-only `--mode=ask`;
- absence of `--force` and `--yolo`;
- workspace root resolution;
- prompt inclusion of task and verification context;
- PASS, FAIL, malformed JSON, CLI failure, and recursion-guard exit behavior.

After automated tests pass, one live smoke test runs the script against this
repository with the authenticated Cursor CLI. The smoke test must not permit
Cursor to edit files.

## Security and Privacy

Cursor review sends repository context to the model provider under the user's
existing Cursor account and policies. The skill must not embed API keys, copy
credentials into prompts, or print authentication material. Users remain
responsible for using the skill only in repositories permitted under those
policies.
