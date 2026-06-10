# unsandbox-git-status — Design

Living design document. Updated when meaningful design decisions land or
get overturned. Not a changelog of features — a record of *why this
plugin has the shape it has*.

## Problem

Claude Code runs Bash commands in a command sandbox by default. The
sandbox overlays the filesystem, and some mounted paths — notably the
agent's `.claude` directory — appear inside the sandbox as phantom
entries: character-device nodes owned by `nobody:nogroup` that do not
exist on the real filesystem. A `git status` run inside the sandbox
enumerates the working tree, sees these phantom entries, and reports them
as untracked or modified content. The agent then reads a status that
disagrees with reality.

Concretely observed: a sandboxed `git status` in a repo with `.claude`
present listed `.claude/agents`, `.claude/commands`, `.claude/hooks`, and
`.claude/skills` as spurious entries; the same `git status` run with the
sandbox disabled showed a clean, correct tree. Teams work around this by
remembering to disable the sandbox for status — but memory is
unreliable, and a polluted status can lead the agent to stage phantom
files or waste turns reconciling noise.

The fix is mechanical and unambiguous: `git status` must run unsandboxed.
This plugin enforces that with a `PreToolUse` hook so it doesn't depend on
anyone remembering — and the hook applies the fix *itself*, rewriting the
call to run unsandboxed rather than asking the agent to retry.

## Functional requirements (FR)

- **FR1** — Force any `git status` invocation that runs with the command
  sandbox enabled to run unsandboxed instead. Do this by rewriting the tool
  call in place (allow + `updatedInput` with `dangerouslyDisableSandbox:
  true`), not by denying it.
- **FR2** — The fix is mechanical: no agent round-trip. The agent is never
  asked to retry, edit, or reason about the command, so it cannot improvise
  a workaround or draw a wrong lesson from the block.
- **FR3** — Pass through untouched any `git status` that is already
  unsandboxed (nothing to fix).
- **FR4** — Touch `git status` only. Every other command, and every other
  git subcommand (`log`, `diff`, `commit`, `add`, …), passes untouched.
- **FR5** — Recognise `git status` across realistic shapes: status flags
  (`-s`, `--porcelain`), git global options including arg-consuming ones
  (`-C <path>`, `-c <k>=<v>`, `--git-dir`, `--no-pager`, …), leading
  `VAR=value` environment assignments, and `git status` appearing as a
  segment of a compound command (`&&`, `;`, `|`).
- **FR6** — No false positives on the common confusables:
  `git commit -m "fix status bar"`, `git log --grep status`,
  `echo "git status"`, `grep "git status" file`.

## Non-functional requirements (NFR)

- **NFR1 — Mechanical.** No agent round-trip; the hook decides on its own.
- **NFR2 — Cheap.** The `matcher` filters by tool name only, so the hook
  fires on *every* Bash call. It must stay at a couple of `jq` parses plus
  string work — no subprocess fan-out, no git invocations.
- **NFR3 — Fail-open.** Malformed or unexpected input (missing command,
  unparseable JSON) passes the call through untouched. Letting an exotic
  `git status` slip through sandboxed only reproduces today's behaviour;
  it is never worse than the status quo.
- **NFR4 — Portable.** `bash` + `jq` only. `sed -E` for the split; no
  GNU-only tooling beyond what Claude Code environments already provide.
- **NFR5 — Self-tested.** A scenario harness (`tests/hook-test.sh`)
  pins deny/allow behaviour and runs in `precommit`.
- **NFR6 — Reproducible releases.** Release infra is the vendored
  `claude-plugin-dev` toolkit, versioned with the repo via subtree.

## Design decisions

### Gate `git status`, nothing else

The phantom-entry problem manifests specifically in working-tree
enumeration, which `git status` does. Other read-only commands (`log`,
`diff`, `show`) don't enumerate the tree the same way, and forcing every
git command — or every command — unsandboxed would defeat the point of
the sandbox. A narrow scope makes the rule defensible and shrinks the
false-positive surface to almost nothing.

### Match the command word, not a substring

A substring match on `git status` false-positives on commit messages
(`git commit -m "…status…"`), grep arguments, and echoed text. Instead the
hook splits the command on shell operators and, per segment:

1. skips leading `VAR=value` environment assignments,
2. requires the next token (the command word) to be exactly `git`,
3. walks git's global options — including the ones that consume the next
   token (`-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`,
   `--exec-path`, `--super-prefix`) — and
4. checks that the first non-option token (the subcommand) is `status`.

This is **precision-biased**: it would rather miss an exotic invocation
than block an unrelated command. The asymmetry is deliberate. A miss
costs nothing beyond the status quo (a sandboxed status slips through, as
it does today). A false positive is disruptive (an unrelated command
blocked mid-task). When in doubt, allow.

### Rewrite via `updatedInput`, not deny-and-retry

The hook emits
`{"hookSpecificOutput": {"permissionDecision": "allow", "updatedInput": …}}`
on stdout and exits 0, where `updatedInput` is the original `tool_input`
with `dangerouslyDisableSandbox` flipped to `true`. Per the hooks API,
`updatedInput` replaces the tool's arguments before it runs, so the command
executes unsandboxed with no further interaction. A one-line `systemMessage`
notes that it happened, for the human and the transcript.

**This overturns the original deny-and-retry design** (`permissionDecision:
"deny"` with an agent-facing `permissionDecisionReason` instructing a
verbatim re-run). That design was correct about the desired end state but
delegated the last step to the agent — and an agent reading a denial reasons
about it instead of mechanically obeying. Observed in practice (Opus 4.8,
2026-06-10): handed "re-run the exact same command with
`dangerouslyDisableSandbox: true`," the model instead *stripped* `git
status` out of an `&&` chain, re-ran the trimmed command, and concluded the
false lesson "don't put `git status` in compound commands." The denial
message led with the *mechanism* (phantom entries), which invited
cause-focused improvisation; it never stated the whole command was blocked
and unrun, so the model hedged rather than retrying verbatim.

The rewrite removes the delegated step entirely. There is no instruction for
the agent to misread, no round-trip, no opportunity to improvise or
mislearn. It is also strictly cheaper (zero extra turns) and degrades more
gracefully on a false positive (see Limitations). The cost is that the fix
is now invisible to the agent by default; the `systemMessage` exists so the
change is not silent, and is phrased as *information* ("ran unsandboxed; no
action needed"), never as an instruction the agent must act on.

### Fire on every Bash call, filter internally

Claude Code's hook `matcher` field matches by *tool name*, not by command
content — there is no documented content matcher for the Bash command
string. So the hook registers on all Bash calls (`matcher: "Bash"`) and
does its own content detection. The cost is one or two `jq` parses per
Bash call, which is negligible (NFR2). The early `exit 0` for
already-unsandboxed calls keeps the common case to a single parse.

### Built on the `claude-plugin-dev` toolkit

Release discipline (bump → commit → tag → push → GitHub release →
marketplace bump) and the `version-guard` hook that protects
`plugin.json` come from the vendored `claude-plugin-dev` toolkit, the same
infrastructure used by the author's other plugins. Vendored via
`git subtree` so old tags reproduce exactly. See that toolkit's own
DESIGN for the reasoning behind subtree-over-submodule and tags-only
versioning.

## Limitations

- **Sandbox-specific premise.** The plugin exists because the sandbox
  exposes phantom mount entries to `git status`. If a future Claude Code
  stops doing that, the hook becomes unnecessary. It stays harmless —
  it only ever forces a status to run unsandboxed.
- **Not configurable.** Only `git status` is gated. Extending to other
  commands means editing the script; there is no config surface.
- **Precision over recall.** Wrapper invocations the matcher doesn't
  model — `sudo git status`, `xargs git status`, `env -S … git status`,
  shell aliases like `g status` — are not caught. Acceptable: a miss only
  reproduces today's behaviour.
- **Over-split on quoted operators.** The segment split is a plain
  `sed` on `&&`/`;`/`|`, not a quote-aware shell parser. A command that
  embeds one of those operators *followed by* `git status …` inside a
  quoted string (e.g. `echo "step 1; git status here"`) over-splits into a
  segment whose command word is `git` and subcommand `status`, producing a
  false-positive match. Under the rewrite design this is benign in effect:
  the command runs unsandboxed and succeeds identically — far gentler than
  the old deny, which blocked the command outright. A full tokenizer would
  remove the misfire at a complexity cost that NFR2/NFR4 don't justify.
- **A false positive silently disables the sandbox for that one call.**
  The flip side of the gentler failure mode: where the old design blocked an
  over-split command (no privilege change), the rewrite runs it unsandboxed
  without announcing the matcher misfired. For the realistic confusables
  (`echo "git status"`, a quoted operator) this is harmless. It is still a
  privilege grant the user didn't request, which is why the matcher stays
  precision-biased — a miss costs nothing, and a false positive should be
  rare enough that silently unsandboxing it is acceptable. The
  `systemMessage` ("ran git status unsandboxed") is the only trace.
- **`jq` dependency, silent if absent.** The hook needs `jq` on `PATH`.
  Combined with fail-open (NFR3), a missing `jq` means the guard quietly
  does nothing rather than erroring — by design, but worth stating.

## History

- **2026-06-07 — initial.** Extracted from a
  project-local `PreToolUse(Bash)` hook first written for the
  `candidature` repo, where a sandboxed `git status` was listing phantom
  `.claude` device nodes. Generalised into a standalone plugin: narrowed
  the contract to `git status`, made the matcher command-word-based with
  global-option walking and compound-command splitting, and added a
  16-scenario hook test (deny/allow plus false-positive guards), green;
  `shellcheck` clean. Built on the vendored `claude-plugin-dev` toolkit,
  subtree-vendored at `plugin-dev/`, with the `version-guard` hook wired
  into `.claude/settings.json`.

- **2026-06-10 — deny-and-retry → transparent rewrite.** Switched the
  enforcement mechanism from `permissionDecision: "deny"` (with an
  agent-facing instruction to re-run unsandboxed) to `permissionDecision:
  "allow"` + `updatedInput`, which flips `dangerouslyDisableSandbox` to
  `true` on the call and lets it run. Prompted by a real failure: handed the
  old denial message, Opus 4.8 stripped `git status` out of an `&&` chain
  instead of retrying verbatim, and mislearned "avoid `git status` in
  compound commands" (the compound chaining is irrelevant; the sandbox is
  the whole problem). Rewriting the call removes the delegated retry step —
  the agent is never asked to do anything, so it cannot improvise or
  mislearn. Rewrote FR1–FR3, the enforcement decision, and the
  false-positive limitation (a misfire now unsandboxes harmlessly rather
  than blocking). The matcher (command-word detection, global-option
  walking, compound-command split) is unchanged; only the action on a match
  changed. Tests updated to assert REWRITE/PASS instead of DENY/ALLOW, plus
  a verbatim-preservation scenario (command and other `tool_input` fields
  survive the flip).
