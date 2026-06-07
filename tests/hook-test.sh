#!/usr/bin/env bash
# End-to-end test of require-unsandboxed-git-status.sh against synthetic
# PreToolUse(Bash) payloads. Each scenario is a real invocation of the hook
# with a hand-crafted JSON input; assertions exit non-zero on failure.
#
# Usage: bash tests/hook-test.sh   (run from repo root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo_root/hooks/require-unsandboxed-git-status.sh"

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# verdict: prints DENY or ALLOW for a (command, dangerouslyDisableSandbox) pair.
verdict() {
  local out
  out="$(jq -nc --arg c "$1" --argjson d "$2" \
    '{tool_name:"Bash", tool_input:{command:$c, dangerouslyDisableSandbox:$d}}' \
    | bash "$hook")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

check() { # $1=command  $2=disabled  $3=expected
  local got
  got="$(verdict "$1" "$2")"
  [ "$got" = "$3" ] || fail "[$1] sandbox_off=$2: expected $3, got $got"
}

# Sandboxed git status in its many shapes: deny.
check 'git status'                              false DENY
check 'git status -s'                           false DENY
check 'git status --porcelain'                  false DENY
check 'git -C /tmp/x status'                    false DENY
check 'git --no-pager status'                   false DENY
check 'git -c color.ui=false status'           false DENY
check 'GIT_PAGER=cat git status'               false DENY
check 'git add . && git status'                false DENY
check 'cd foo; git status'                      false DENY

# Unsandboxed git status: allow.
check 'git status'                              true  ALLOW

# Not git status: allow (false-positive guards).
check 'git commit -m "fix status bar"'         false ALLOW
check 'git log --grep status'                   false ALLOW
check 'git stash'                               false ALLOW
check 'echo "git status"'                       false ALLOW
check 'grep "git status" file.txt'             false ALLOW
check 'ls -la'                                   false ALLOW

if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'all hook scenarios passed\n'
