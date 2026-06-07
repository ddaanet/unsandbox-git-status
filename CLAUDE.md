# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

# Agent Instructions — unsandbox-git-status

This repository **is** a Claude Code plugin. Its single deliverable is a
`PreToolUse(Bash)` hook that forces `git status` to run with the command
sandbox disabled. The hook ships to end-users' sessions; keep that in
mind when editing — its output is read by another agent, not a human.

## Layout

- `.claude-plugin/plugin.json` — plugin manifest. `.version` holds the
  **last released** version and is owned by `just release`. Do not edit
  it by hand (the vendored version-guard hook blocks that).
- `hooks/hooks.json` — registers the `PreToolUse(Bash)` hook. The command
  uses `${CLAUDE_PLUGIN_ROOT}`, which Claude Code expands at fire time.
- `hooks/require-unsandboxed-git-status.sh` — the hook itself. Reads the
  PreToolUse JSON on stdin, denies a sandboxed `git status`, allows
  everything else.
- `tests/hook-test.sh` — scenario test for the hook. Deny and allow
  cases, including false-positive guards. Runs in `precommit`.
- `plugin-dev/` — vendored `claude-plugin-dev` release toolkit (subtree).
  Provides the `release` recipe and the `version-guard` hook.
- `DESIGN.md` — living rationale: FR, NFR, decisions, limitations,
  history. Update it when design choices change.

## Quality gate

```sh
just precommit
```

Runs `shellcheck` and `bash -n` on the hook and test, then executes the
hook test. Must be green before committing.

## The hook's contract

- **Fail-open.** Any unexpected input (missing command, unparseable JSON,
  already-unsandboxed call) must result in exit 0 / allow. Never block on
  uncertainty — blocking real work is worse than missing an exotic
  `git status`.
- **Match the command word, not a substring.** Detection splits on shell
  operators and, per segment, checks that the command word is `git`
  (after skipping `VAR=value` env assignments) and the subcommand is
  `status` (after walking git's global options, including arg-consuming
  ones like `-C` and `-c`). This is what keeps `git commit -m "...status"`
  and `echo "git status"` from being denied. Preserve this bias when
  changing the matcher: prefer a miss over a false positive.
- **Dual-channel output.** On deny, `permissionDecisionReason` is the
  agent-facing instruction (re-run with `dangerouslyDisableSandbox`);
  `systemMessage` is the one-line human notice. Do not soften the agent
  reason into something that reads as an optional suggestion, and do not
  add escape hatches the agent could self-authorise.
- **Cheap.** The hook fires on every Bash call (the `matcher` filters by
  tool name only). Keep it to jq parses and string work — no subprocess
  fan-out.

## Releasing

```sh
just release [patch|minor|major]
```

Bumps `plugin.json`, commits `release: X.Y.Z`, tags, pushes, creates a
GitHub release, and bumps the marketplace entry. Requires `MARKETPLACE_DIR`
set (see `.envrc`). The manifest version represents the last released
version; `release` bumps from there. The first release is `minor`
(`0.0.0 → 0.1.0`).

## Conventions

- **Tests are the spec.** Any change to the matcher must come with a
  scenario in `tests/hook-test.sh` that pins the new behaviour. Add the
  failing case first.
- **Update `DESIGN.md` when decisions change.** History accretes;
  overturned decisions are rewritten in place with the new reasoning.
- **Don't edit `plugin-dev/`.** It is vendored. Update it with
  `just update-plugin-dev vX.Y.Z`.
- **`${CLAUDE_PLUGIN_ROOT}` in `hooks/hooks.json` is expanded by Claude
  Code, not by bash at author time.** Keep it double-quoted.
