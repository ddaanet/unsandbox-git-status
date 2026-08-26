import 'plugin-dev/release.just'

_default:
    @just --list

# Syntax, style, and behaviour checks. `release` depends on this.
precommit:
    jq empty .claude-plugin/plugin.json
    jq empty hooks/hooks.json
    shellcheck hooks/require-unsandboxed-git-status.sh tests/hook-test.sh
    bash -n hooks/require-unsandboxed-git-status.sh tests/hook-test.sh
    bash tests/hook-test.sh
    @echo ok

# Gate for `just release` (required by the vendored plugin-dev toolkit).
prerelease: precommit
