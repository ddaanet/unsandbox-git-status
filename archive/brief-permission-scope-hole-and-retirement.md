# Brief: `permissionDecision: "allow"` unsandboxes and pre-approves the whole command

Written from the gitlore repo, where a review of the `sandbox-effects` memory
decompiled Claude Code's permission pipeline from the 2.1.233 bundle. This is a
proposal, not a change: nothing in this repo has been edited.

## The finding

`hooks/require-unsandboxed-git-status.sh` segments the command only to *detect*
a `git status`, then re-emits `.tool_input` verbatim with one field flipped
(line 67), alongside `permissionDecision: "allow"` (line 76).

Two consequences follow, and the second is the one that matters.

**Scope.** The rewrite carries the whole `tool_input` through, so a compound
containing a `git status` segment runs unsandboxed *in its entirety* —
`git status && <anything>`. This part is already documented in the repo.

**Gate.** `permissionDecision: "allow"` does not merely defer the decision; it
settles it. From the bundle:

- With `updatedInput` **alone**, `HRn` yields `{type:"hookUpdatedInput"}`, the
  caller assigns the rewritten input, and `PDb` runs the *full* permission
  pipeline over it. The command is no longer sandboxed, so
  `autoAllowBashIfSandboxed` no longer applies and the auto-mode classifier
  weighs it. This is the safe construction.
- With `permissionDecision: "allow"`, the only remaining re-check is `rIt`,
  which returns non-null solely for a matching deny rule, a matching ask rule,
  or two narrow ask reasons. A `passthrough` from `checkPermissions` yields
  `null` and the hook's allow stands.

So any command carrying a `git status` segment runs unsandboxed **and**
pre-approved, with the classifier never consulted on the rest of it. Confirmed
live: `true && git status --porcelain` was rewritten and ran.

The fix, if the hook stays, is to drop `permissionDecision` and emit
`updatedInput` alone. That costs nothing on the happy path — a bare `git
status` is classified read-only and auto-allowed ahead of the classifier
anyway — and it restores the gate for everything bundled alongside it.

## The hook is now largely superseded

User-scope `~/.claude/settings.json` now carries

```json
"sandbox": {"excludedCommands": ["git:*", "find:*", "ls:*", "claude:*"]}
```

`git:*` covers every git invocation, not the best-effort `git status` subset,
and it reaches forms the hook's matcher misses. Verified live against CC
2.1.234: `git log -1 --oneline` runs with `$TMPDIR` unset, and `ls -a` returns
a tree carrying none of the 22 phantom masks.

Two differences remain in the exclusion's favour:

- native `excludedCommands` is honoured in strict sandbox mode, where
  `dangerouslyDisableSandbox` is refused outright;
- it does **not** settle the permission gate, so unsandboxed commands stay
  classifier-evaluated — which is exactly the hole above.

One difference is not in its favour: the exclusion matcher never descends into
`( … )`, `$( … )` or `sh -c '…'`, so a subshell-wrapped `git status` stays
sandboxed where the hook's substring detection would have caught it. In
practice that form should stop being generated — a separate brief in the
`cwd-safety` repo proposes removing the rewrite that produces it.

## Suggested sequencing

1. Drop `permissionDecision: "allow"` — this stands on its own and is worth
   doing whether or not the hook is retired.
2. Let the exclusions run for a while and watch for any `git` shape they miss.
3. Retire the hook once nothing turns up.

Retiring before step 2 is the risky order: the hook carries the large majority
of `git status` traffic today, so removing it and the exclusions in one motion
leaves no fallback if the matcher has a gap.

## One correction to the repo's own notes

The plugin's notice is documented as going to `systemMessage` only — user
channel, not model context. That is stale: the hook emits `additionalContext`
as well (line 76), and it arrived in the model's tool results in this session.

## What this brief is not

It is a proposal from a session whose consent scope was the gitlore working
directory. No file here was modified, and nothing is being tracked on this
repo's behalf — pick it up, discard it, or ask for the underlying
decompilation, whichever fits.
