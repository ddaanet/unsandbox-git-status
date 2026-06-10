## Current task

Changed the unsandbox-git-status hook from deny-and-retry to a transparent
`updatedInput` rewrite (allow + flip `dangerouslyDisableSandbox` to true) so a
sandboxed `git status` runs unsandboxed with no agent round-trip — implemented,
gate-green, about to commit.

## Open decisions

- Whether to cut the first release now (`just release minor` → v0.1.0, still
  v0.0.0/unreleased) and add the marketplace entry to ddaanet/claude-plugins.
- Whether to clean up the untracked working inputs (brief-hook-message-clarity.md
  and the 2026-06-10 session .txt) — they are inputs, not part of the deliverable.
