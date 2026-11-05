#!/usr/bin/env bash
# Assert that the managed config is in force for one agent. Hermes FAILS OPEN on a missing or invalid
# /etc/hermes/config.yaml, so run this after every config change, rebuild or restart.
# Dry-run by default: prints the checks. --run executes them with `docker compose exec` inside the agent container.
# Usage: [EXPECT_GH_LOGIN=<machine-user>] scripts/check-config.sh [--run] <agent-name>
set -euo pipefail

run=0
if [[ "${1:-}" == "--run" ]]; then run=1; shift; fi
agent="${1:-}"
[[ "$agent" =~ ^agent-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "usage: $0 [--run] <agent-name>" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose=(docker compose -f "$root/compose.yaml")
fail=0

# Expected values: keep in sync with agents/<agent>/managed-config.yaml.
EXPECT_APPROVALS="manual"
EXPECT_TOOLSETS="clarify file memory session_search skills terminal todo"
# Login of the agent's GitHub machine user. Not known to the starter: set it to enable the identity check.
EXPECT_GH_LOGIN="${EXPECT_GH_LOGIN:-}"

# check <description> <expected output> <command run inside the agent container>
check() {
  local desc="$1" expect="$2"; shift 2
  echo "- $desc (expect: $expect)"
  echo "    + ${compose[*]} exec -T $agent $*"
  (( run )) || return 0
  local out
  out="$("${compose[@]}" exec -T "$agent" "$@" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')" || true
  if [[ "$out" == "$expect" ]]; then
    echo "    PASS"
  else
    echo "    FAIL (got: ${out:-<nothing>})"; fail=1
  fi
}

(( run )) || echo "DRY RUN (nothing executed). Re-run with --run against a running stack."

check "managed config mounted read-only" "ro" \
  sh -c 'test -r /etc/hermes/config.yaml && ! touch /etc/hermes/config.yaml 2>/dev/null && echo ro'
check "approvals.mode" "$EXPECT_APPROVALS" \
  hermes config get approvals.mode
for platform in slack cli; do
  check "enabled toolsets ($platform)" "$EXPECT_TOOLSETS" \
    sh -c "hermes tools list --platform $platform 2>/dev/null | awk '/enabled/ && !/disabled/ {print \$3}' | sort"
done
check "gh present" "ok" \
  sh -c 'gh --version >/dev/null && echo ok'
# shellcheck disable=SC2016  # expanded inside the container, not here
check "GitHub token not in the container env" "absent" \
  sh -c 'if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then echo present; else echo absent; fi'
check "GitHub token file read-only, owned by the agent (uid:gid mode)" "10000:10000 400" \
  sh -c 'stat -c "%u:%g %a" /etc/agent/github_token'
# Read-only API call through the wrapper; prints only the login, never the token.
if [[ -n "$EXPECT_GH_LOGIN" ]]; then
  check "gh authenticates as the machine user" "$EXPECT_GH_LOGIN" \
    gh api user --jq .login
else
  echo "- gh authenticates as the machine user: SKIPPED (set EXPECT_GH_LOGIN=<login> to enable)"
fi
check "git uses gh as credential helper for github.com" "!gh auth git-credential" \
  sh -c 'git config --get-all credential.https://github.com.helper | tail -n 1'

(( run )) && { (( fail )) && { echo "RESULT: FAIL"; exit 1; } || echo "RESULT: PASS"; }
exit 0
