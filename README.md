# unsandbox-git-status

> **Retired 2026-08-26.** No longer maintained or recommended. Claude Code's
> native `sandbox.excludedCommands` setting does the same job for *every*
> `git` invocation, not just `git status`, is honoured in strict sandbox
> mode, and does not pre-approve the command the way this hook did:
>
> ```json
> "sandbox": { "excludedCommands": ["git:*"] }
> ```
>
> in `~/.claude/settings.json`. The code stays as a record; see `DESIGN.md`
> (status note, Limitations, History 2026-08-26) for what was found and why
> the plugin was retired rather than fixed.

A Claude Code plugin that forces `git status` to run with the command
sandbox **disabled**.

## Why

Under Claude Code's command sandbox, mounted paths (notably the agent's
`.claude` directory) surface as phantom entries in a repository's working
tree — character-device nodes that exist only inside the sandbox view. A
`git status` run inside the sandbox sees them and reports files that are
not actually there, so the agent reads a polluted, untrustworthy status.
The same command run unsandboxed reports the real working tree.

This plugin closed that gap mechanically: it intercepted `git status`
before it ran and, if the call was sandboxed, rewrote it in place to run
with the sandbox off.

## What it does

- A `PreToolUse(Bash)` hook inspects every Bash command.
- If a segment is a `git status` invocation **and** the call is sandboxed,
  it rewrites the call (`permissionDecision: "allow"` + `updatedInput`)
  with `dangerouslyDisableSandbox: true`, so it runs unsandboxed with no
  agent round-trip.
- Everything else passes untouched — other commands, other git
  subcommands, and any `git status` that is already unsandboxed.

It is precision-biased: it would rather let an exotic invocation through
than block an unrelated command. `git commit -m "fix status bar"`,
`git log --grep status`, and `echo "git status"` all pass.

## Install

```sh
/plugin marketplace add ddaanet/claude-plugins
/plugin install unsandbox-git-status@ddaanet
/reload-plugins
```

Replace the marketplace ref with wherever this plugin is published. After
installing, the hook is active in new sessions (run `/reload-plugins` to
pick it up in the current one).

## Verify

When it fires you will see a one-line notice — "unsandboxed call
containing git status" — and the agent receives a matching
`additionalContext` note saying the call was rewritten.

## Requirements

`bash`, `jq`.

## Development

```sh
just precommit   # shellcheck + syntax + the hook test
just release minor
```

See `DESIGN.md` for the rationale and `CLAUDE.md` for agent-facing
working notes. Release tooling is the vendored
[`claude-plugin-dev`](https://github.com/ddaanet/claude-plugin-dev)
toolkit under `plugin-dev/`.

## License

MIT
