#!/usr/bin/env bash
# Delete ONE agent's persisted state (sessions, memories, logs, credentials) for data-subject deletion
# requests and retention expiry. Dry-run by default; --apply plus --yes performs the deletion.
# Usage: scripts/wipe-agent.sh [--apply --yes] <agent-name>      (for example: agent-example)
set -euo pipefail

apply=0; yes=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --apply) apply=1 ;;
    --yes) yes=1 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
agent="${1:-}"
[[ "$agent" =~ ^agent-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "usage: $0 [--apply --yes] <agent-name>" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data="$root/data/$agent"
service="$agent"

[[ -d "$data" ]] || { echo "nothing to wipe: $data does not exist"; exit 0; }

# Single-writer rule: never delete under a running container.
if [[ -n "$(docker compose -f "$root/compose.yaml" ps --status running -q "$service" 2>/dev/null)" ]]; then
  echo "refusing: $service is running. Stop it first: docker compose stop $service" >&2
  exit 1
fi

echo "would delete the contents of: $data"
sudo -n find "$data" -mindepth 1 -maxdepth 1 -printf '  %f\n' 2>/dev/null || echo '  (listing needs sudo; run with sudo credentials cached)'

if (( ! apply )); then echo "DRY RUN (no changes). Use --apply --yes to delete."; exit 0; fi
(( yes )) || { echo "--apply needs --yes to confirm irreversible deletion" >&2; exit 2; }

sudo find "$data" -mindepth 1 -delete
echo "wiped $agent state. Re-seed with: scripts/init-dirs.sh --apply $agent"
echo "note: provider-side logs and rotated API keys are outside this script; revoke the agent's key if retiring it."
