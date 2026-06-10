## Brief: unsandbox-git-status — hook message drove the wrong recovery

2026-06-10

### The issue we hit

The PreToolUse hook (`hooks/require-unsandboxed-git-status.sh`) blocked a
sandboxed Bash command that contained `git status` and returned this message:

> git status was run sandboxed. Re-run the exact same Bash command with
> dangerouslyDisableSandbox set to true. Under the command sandbox, mounted
> artifacts surface as phantom working-tree entries, so a sandboxed git status
> misreports the repository state. This applies only to git status; other
> commands and other git subcommands are unaffected.

Given that message, the model (Opus 4.8) did **not** do what it said. Instead it:

1. Edited the command — stripped `git status` out of the `&&` chain, re-ran the
   trimmed `git add && git commit`, and checked status in a separate call.
2. Drew the wrong general lesson: *"don't put git status in a compound command."*
   That is false — the compound chaining is irrelevant; the sandbox is the only
   problem. Encoding that lesson would have been a lasting mistake.

### Root cause (of the model's behavior, not the sandbox)

The message is accurate but mis-weighted for an LLM reader:

- It **leads with the mechanism** ("phantom working-tree entries…"). Leading with
  cause invited cause-focused improvisation (model reasoned "git status is the
  culprit → remove it") instead of executing the prescribed action.
- It does not state that the **entire command was blocked and did not run**, so
  the model couldn't be sure a verbatim retry was free of double-effects, and
  hedged by trimming + verifying separately.
- It frames recovery as reactive ("re-run") rather than a standing rule, so the
  model never internalized "run git-status commands unsandboxed from the start."

### Suggested fix

Rewrite the denial message, action-first and unambiguous. Suggested wording:

> **Re-run this exact command unchanged with `dangerouslyDisableSandbox: true`.**
> The command was blocked entirely and did NOT run — a verbatim retry is safe,
> no double effect. Do not edit, split, or remove `git status`; compound `&&`
> chains are fine. The sandbox is the only problem: it surfaces mounted artifacts
> as phantom working-tree entries, so `git status` misreports under it. Rule:
> always run any command containing `git status` unsandboxed.

Order matters: action → "nothing ran, retry is safe" → "don't alter the command"
→ mechanism last.

### Rejected approach (do not encode)

"Avoid `git status` in compound commands." Wrong — this was the model's mistaken
takeaway. Composition is irrelevant; only the sandbox flag matters.

### Worth investigating (preferred if feasible)

Can the hook be **proactive/transparent** instead of a deny-and-retry round-trip?
Options for the worktree agent to weigh against the Claude Code hook API
(`plugin-dev:hook-development`):

- A SessionStart/context-injection that states the standing rule up front, so the
  block rarely fires.
- If the PreToolUse API can mutate tool input, set `dangerouslyDisableSandbox`
  automatically on git-status commands (no model round-trip at all). If not
  supported, the message rewrite above is the fallback.

### Additional context

- Repo: `/Users/david/code/unsandbox-git-status` (working dir for this session).
- Hook script: `hooks/require-unsandboxed-git-status.sh`. Installed cache copy
  seen at `~/.claude/plugins/cache/ddaanet/unsandbox-git-status/0.1.0/`.
- The block aborts the whole compound command before any subcommand runs
  (confirmed this session: `git log` was unchanged after the block).
