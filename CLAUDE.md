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
  PreToolUse JSON on stdin, rewrites a sandboxed `git status` to run
  unsandboxed (allow + `updatedInput`), passes everything else through.
- `tests/hook-test.sh` — scenario test for the hook. Deny and allow
  cases, including false-positive guards. Runs in `precommit`.
- `plugin-dev/` — vendored `claude-plugin-dev` release toolkit (subtree).
  Provides the `release` recipe and the `version-guard` hook.
- `memory/` — gitlore memory store, a **git submodule**
  (`unsandbox-git-status-memory.git`), not a regular directory. `.gitlore/bin`
  is added to `PATH` by `.envrc`.
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
  already-unsandboxed call) must result in exit 0 with no rewrite — the call
  passes through untouched. Never act on uncertainty: an exotic `git status`
  slipping through sandboxed only reproduces today's behaviour, whereas
  rewriting the wrong command silently disables its sandbox.
- **Match the command word, not a substring.** Detection splits on shell
  operators and, per segment, checks that the command word is `git`
  (after skipping `VAR=value` env assignments) and the subcommand is
  `status` (after walking git's global options, including arg-consuming
  ones like `-C` and `-c`). This is what keeps `git commit -m "...status"`
  and `echo "git status"` from being rewritten. Preserve this bias when
  changing the matcher: prefer a miss over a false positive — a miss just
  reproduces today's behaviour, a false positive silently unsandboxes an
  unrelated command.
- **Rewrite, don't deny.** On a match the hook emits `permissionDecision:
  "allow"` with `updatedInput` — the original `tool_input` with
  `dangerouslyDisableSandbox` flipped to `true` — so the command runs
  unsandboxed with no agent round-trip. Build `updatedInput` from the real
  `tool_input` (`jq '.tool_input | .dangerouslyDisableSandbox = true'`) so
  the command and every other field survive verbatim; never reconstruct it
  by hand. The old deny-and-retry design was overturned because agents
  reason about a denial instead of obeying it (see DESIGN history,
  2026-06-10).
- **Announce on both channels, as information.** `systemMessage` is a
  one-line human notice; `additionalContext` tells the *agent* the call was
  rewritten. Both are needed — `systemMessage` never enters the model's
  context, and an unannounced rewrite teaches the agent that a sandboxed
  `git status` is trustworthy. Keep both as information, never an
  instruction the agent must act on, and claim only what the hook knows: it
  rewrote this call. It does not know whether a sandboxed `git status`
  misreports on the current harness, so the agent-facing text says the
  output is no evidence either way rather than asserting the sandbox is
  still broken.
- **Cheap.** The hook fires on every Bash call (the `matcher` filters by
  tool name only). Keep it to jq parses and string work — no subprocess
  fan-out.

## Releasing

```sh
just release [patch|minor|major]
```

Bumps `plugin.json`, commits `release: X.Y.Z`, tags, pushes, creates a
GitHub release, and bumps the marketplace entry. Requires `MARKETPLACE_DIR`
set (inherited from the parent directory's `.envrc` via `source_up_if_exists`).
The manifest version represents the last released
version; `release` bumps from there. The first release is `minor`
(`0.0.0 → 0.1.0`).

## Tooling hooks

Two hooks affect committing in this repo:
- **gitmoji** rewrites conventional-commit prefixes to emoji on commit
  (so `release: X.Y.Z` lands as an emoji-prefixed message).
- **gitlore** may block a commit/push with a memory-merge prompt; resolve it
  with `/gitlore:resolve`.

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
