#!/usr/bin/env bash
# Assert the egress policy for one agent. Requires the stack to be running (docker compose up is a separate, explicit step).
# Dry-run by default: prints the checks. --run executes them with `docker compose exec` inside the agent container.
# Usage: scripts/check-egress.sh [--run] <agent-name>      (for example: agent-example)
set -euo pipefail

ALLOWED_HOST="api.anthropic.com"   # must match proxy/squid-<agent>.conf
BLOCKED_HOST="example.com"         # arbitrary public host that must NOT be allowlisted

run=0
if [[ "${1:-}" == "--run" ]]; then run=1; shift; fi
agent="${1:-}"
[[ "$agent" =~ ^agent-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "usage: $0 [--run] <agent-name>" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose=(docker compose -f "$root/compose.yaml")
fail=0

# check <description> <expect: ok|fail> <command run inside the agent container>
check() {
  local desc="$1" expect="$2"; shift 2
  echo "- $desc (expect: $expect)"
  echo "    + ${compose[*]} exec -T $agent $*"
  (( run )) || return 0
  local rc=0
  "${compose[@]}" exec -T "$agent" "$@" >/dev/null 2>&1 || rc=$?
  if { [[ "$expect" == ok && $rc -eq 0 ]] || [[ "$expect" == fail && $rc -ne 0 ]]; }; then
    echo "    PASS"
  else
    echo "    FAIL (exit $rc)"; fail=1
  fi
}

(( run )) || echo "DRY RUN (nothing executed). Re-run with --run against a running stack."

# No --fail: any HTTP status from the allowed host counts as reachable; a denied CONNECT makes curl exit non-zero. VERIFY curl exists in the image.
check "allowed endpoint reachable through the proxy" ok \
  sh -c 'curl -sS --max-time 15 -o /dev/null "https://'"$ALLOWED_HOST"'/"'
check "arbitrary public host blocked by the proxy" fail \
  sh -c 'curl -sS --max-time 15 -o /dev/null "https://'"$BLOCKED_HOST"'/"'
check "direct connection bypassing the proxy has no route" fail \
  sh -c 'curl -sS --noproxy "*" --max-time 8 -o /dev/null "https://'"$BLOCKED_HOST"'/"'
check "direct connection to a raw IP has no route" fail \
  sh -c 'curl -sS --noproxy "*" --max-time 8 -o /dev/null "https://1.1.1.1/"'

# Other agents are the other compose services named agent-*. Only looked up on --run: a dry run must not need
# the secret files that `docker compose config` insists on.
others=()
if (( run )); then
  while IFS= read -r svc; do
    [[ "$svc" == agent-* && "$svc" != "$agent" ]] && others+=("$svc")
  done < <("${compose[@]}" config --services)
else
  echo "- (on --run) every other agent-* service must be unreachable from $agent"
fi
for other in "${others[@]}"; do
  check "other agent ($other) not resolvable/reachable from $agent" fail \
    sh -c 'curl -sS --noproxy "*" --max-time 5 -o /dev/null "http://'"$other"':8642/"'
done
(( run && ${#others[@]} == 0 )) && echo "- no other agent-* service defined: cross-agent isolation is not exercised"

echo "known gap: Docker's embedded DNS may still resolve external names from internal networks (DNS exfiltration channel); not tested here."
(( run )) && { (( fail )) && { echo "RESULT: FAIL"; exit 1; } || echo "RESULT: PASS"; }
exit 0
