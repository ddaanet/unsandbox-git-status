#!/usr/bin/env bash
# PreToolUse(Bash) guard: require `git status` to run with the command
# sandbox disabled.
#
# Under the Claude Code command sandbox, mounted artifacts can surface as
# phantom entries in a repository's working tree, so a sandboxed `git status`
# reports files that do not exist on the real filesystem. Running git status
# unsandboxed reports the true state. This hook denies a sandboxed `git status`
# and tells the agent to re-run the same Bash call with
# dangerouslyDisableSandbox set to true.
#
# Scope is deliberately narrow: only `git status` is gated. Every other command,
# including every other git subcommand, passes untouched. See DESIGN.md.

set -euo pipefail

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
sandbox_disabled=$(printf '%s' "$input" | jq -r '.tool_input.dangerouslyDisableSandbox // false')

# Already unsandboxed, or not a Bash call with a command: nothing to gate.
[ "$sandbox_disabled" = "true" ] && exit 0
[ -n "$command" ] || exit 0

# Split on shell operators so each pipeline segment is inspected on its own. A
# quoted operator can over-split, but the command-word check below keeps that
# from misfiring into a false denial.
segments=$(printf '%s' "$command" | sed -E 's/(\|\||&&|[;|&\n])/\n/g')

# True when a segment's command word is `git` and its subcommand is `status`,
# walking past git's global options (including the ones that consume the next
# token, like `-C <path>` and `-c <key>=<value>`).
is_git_status() {
  local seg="$1"
  # shellcheck disable=SC2206
  local toks=($seg)
  local i=0 n=${#toks[@]}
  # Skip leading VAR=value environment assignments.
  while [ "$i" -lt "$n" ] && [[ "${toks[$i]}" == *=* && "${toks[$i]}" != -* && "${toks[$i]%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; do
    i=$((i + 1))
  done
  { [ "$i" -lt "$n" ] && [ "${toks[$i]}" = "git" ]; } || return 1
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      -C | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix | -c)
        i=$((i + 2)) ;;
      --*=* | -*)
        i=$((i + 1)) ;;
      *)
        [ "${toks[$i]}" = "status" ] && return 0 || return 1 ;;
    esac
  done
  return 1
}

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  if is_git_status "$seg"; then
    agent_reason="git status was run sandboxed. Re-run the exact same Bash command with dangerouslyDisableSandbox set to true. Under the command sandbox, mounted artifacts surface as phantom working-tree entries, so a sandboxed git status misreports the repository state. This applies only to git status; other commands and other git subcommands are unaffected."
    human_msg="unsandbox-git-status: blocked a sandboxed git status (re-run unsandboxed)"
    jq -nc --arg r "$agent_reason" --arg s "$human_msg" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
    exit 0
  fi
done <<EOF
$segments
EOF

exit 0
