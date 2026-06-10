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

# run: feeds a (command, dangerouslyDisableSandbox) pair to the hook and prints
# its raw stdout.
run() {
  jq -nc --arg c "$1" --argjson d "$2" \
    '{tool_name:"Bash", tool_input:{command:$c, dangerouslyDisableSandbox:$d}}' \
    | bash "$hook"
}

# verdict: REWRITE when the hook forces the call unsandboxed (allow +
# updatedInput.dangerouslyDisableSandbox=true); PASS when it lets the call
# through untouched (no output).
verdict() {
  if printf '%s' "$1" | jq -e \
    '.hookSpecificOutput.permissionDecision == "allow"
      and .hookSpecificOutput.updatedInput.dangerouslyDisableSandbox == true' \
    >/dev/null 2>&1; then
    printf 'REWRITE'
  else
    printf 'PASS'
  fi
}

check() { # $1=command  $2=disabled  $3=expected
  local got
  got="$(verdict "$(run "$1" "$2")")"
  [ "$got" = "$3" ] || fail "[$1] sandbox_off=$2: expected $3, got $got"
}

# Sandboxed git status in its many shapes: force unsandboxed.
check 'git status'                              false REWRITE
check 'git status -s'                           false REWRITE
check 'git status --porcelain'                  false REWRITE
check 'git -C /tmp/x status'                    false REWRITE
check 'git --no-pager status'                   false REWRITE
check 'git -c color.ui=false status'           false REWRITE
check 'GIT_PAGER=cat git status'               false REWRITE
check 'git add . && git status'                false REWRITE
check 'cd foo; git status'                      false REWRITE

# Already unsandboxed: nothing to do, pass through.
check 'git status'                              true  PASS

# Not git status: pass through untouched (false-positive guards). Forcing an
# unrelated command unsandboxed would be a needless privilege grant, so these
# must NOT be rewritten.
check 'git commit -m "fix status bar"'         false PASS
check 'git log --grep status'                   false PASS
check 'git stash'                               false PASS
check 'echo "git status"'                       false PASS
check 'grep "git status" file.txt'             false PASS
check 'ls -la'                                   false PASS

# The rewrite must be surgical: preserve the command verbatim and every other
# tool_input field, flipping only the sandbox flag. A verbatim re-run is the
# whole point — no edit, no split, no dropped argument.
preserve_out="$(jq -nc \
  '{tool_name:"Bash", tool_input:{command:"git add . && git status -s",
    description:"stage and check", timeout:5000, dangerouslyDisableSandbox:false}}' \
  | bash "$hook")"

got_cmd="$(printf '%s' "$preserve_out" | jq -r '.hookSpecificOutput.updatedInput.command')"
[ "$got_cmd" = 'git add . && git status -s' ] \
  || fail "rewrite altered the command: got [$got_cmd]"

got_desc="$(printf '%s' "$preserve_out" | jq -r '.hookSpecificOutput.updatedInput.description')"
[ "$got_desc" = 'stage and check' ] \
  || fail "rewrite dropped the description field: got [$got_desc]"

got_timeout="$(printf '%s' "$preserve_out" | jq -r '.hookSpecificOutput.updatedInput.timeout')"
[ "$got_timeout" = '5000' ] \
  || fail "rewrite dropped the timeout field: got [$got_timeout]"

if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'all hook scenarios passed\n'
