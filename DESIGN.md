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
anyone remembering.

## Functional requirements (FR)

- **FR1** — Deny any `git status` invocation that runs with the command
  sandbox enabled.
- **FR2** — On deny, instruct the agent to re-run the *identical* command
  with `dangerouslyDisableSandbox: true`.
- **FR3** — Allow `git status` when the call is already unsandboxed.
- **FR4** — Gate `git status` only. Every other command, and every other
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
  unparseable JSON) allows the call. Blocking real work is worse than
  letting an exotic `git status` slip through.
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

### Deny via `permissionDecision`, exit 0

The hook emits
`{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": …}}`
on stdout and exits 0, with a `systemMessage` for the human channel. This
is the documented rich-permission mechanism and lets the hook carry two
distinct messages:

- `permissionDecisionReason` — agent-facing, an unconditional instruction
  to re-run with the sandbox flag. No escape hatches the agent could read
  as "optional."
- `systemMessage` — one curt line for the human, surfacing *that* a block
  happened.

The alternative (exit 2 with the reason on stderr) also blocks, but the
JSON/`permissionDecision` path is the canonical way to express a deny
decision and to split the two channels cleanly. The split matters because
agents read instructions literally: a diagnostic worded for humans that
mentions a bypass gets parsed as permission to bypass.

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

### Manifest version starts at `0.0.0`

The plugin has not been released yet. Following the toolkit's invariant
that the manifest holds the *last released* version, an unreleased plugin
is `0.0.0`; the first `just release minor` cuts `v0.1.0`.

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
  false-positive deny. This is rare and low-cost (the agent re-runs
  unsandboxed and the echo succeeds). A full tokenizer would fix it at the
  cost of complexity that NFR2/NFR4 don't justify.
- **`jq` dependency, silent if absent.** The hook needs `jq` on `PATH`.
  Combined with fail-open (NFR3), a missing `jq` means the guard quietly
  does nothing rather than erroring — by design, but worth stating.

## History

- **2026-06-07 — initial (`v0.0.0`, unreleased).** Extracted from a
  project-local `PreToolUse(Bash)` hook first written for the
  `candidature` repo, where a sandboxed `git status` was listing phantom
  `.claude` device nodes. Generalised into a standalone plugin: narrowed
  the contract to `git status`, made the matcher command-word-based with
  global-option walking and compound-command splitting, and added a
  16-scenario hook test (deny/allow plus false-positive guards), green;
  `shellcheck` clean. Built on `claude-plugin-dev` v0.2.0, subtree-vendored
  at `plugin-dev/`, with the `version-guard` hook wired into
  `.claude/settings.json`.

  Next: first release via `just release minor` (→ `v0.1.0`), then add the
  marketplace entry to `ddaanet/claude-plugins` so end users can install
  it.
