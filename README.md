# unsandbox-git-status

A Claude Code plugin that forces `git status` to run with the command
sandbox **disabled**.

## Why

Under Claude Code's command sandbox, mounted paths (notably the agent's
`.claude` directory) surface as phantom entries in a repository's working
tree — character-device nodes that exist only inside the sandbox view. A
`git status` run inside the sandbox sees them and reports files that are
not actually there, so the agent reads a polluted, untrustworthy status.
The same command run unsandboxed reports the real working tree.

This plugin closes that gap mechanically: it intercepts `git status`
before it runs and, if the call is sandboxed, denies it with an
instruction to re-run the identical command with the sandbox off.

## What it does

- A `PreToolUse(Bash)` hook inspects every Bash command.
- If a segment is a `git status` invocation **and** the call is sandboxed,
  it denies the call and tells the agent to re-run with
  `dangerouslyDisableSandbox: true`.
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

When it fires you will see the call denied with a reason like:

> git status was run sandboxed. Re-run the exact same Bash command with
> dangerouslyDisableSandbox set to true.

The agent then re-issues the command unsandboxed and gets the true status.

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
