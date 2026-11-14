#!/usr/bin/env bash
# Create per-agent data dirs and seed config templates. Linux: mode 700, owned by the container UID (needs sudo).
# macOS: mode 700, owned by you (no sudo; Docker Desktop reaches bind mounts as the host user).
# Dry-run by default: prints what it would do. Use --apply to act. Idempotent. Works with bash 3.2 (macOS).
# Usage: scripts/init-dirs.sh [--apply] <agent-name>      (for example: agent-example)
set -euo pipefail

CONTAINER_UID=10000   # VERIFY for the pinned image version
CONTAINER_GID=10000

apply=0
if [[ "${1:-}" == "--apply" ]]; then apply=1; shift; fi
agent="${1:-}"
[[ "$agent" =~ ^agent-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "usage: $0 [--apply] <agent-name>" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data="$root/data/$agent"
tpl="$root/agents/$agent"
[[ -d "$tpl" ]] || { echo "no such agent: $tpl does not exist" >&2; exit 2; }

# Linux: the bind-mounted dir must belong to the container user, which needs root; the host user then needs sudo to
# read it (intended). macOS: Docker Desktop's file sharing runs file access as the host user, so UID 10000 ownership
# is neither needed nor reliable there; own the files as yourself and do not use sudo. UNTESTED on a real Mac.
if [[ "$(uname -s)" == "Darwin" ]]; then
  as_root=(); owner=()
  echo "platform: macOS, files owned by $(id -un), no sudo"
else
  as_root=(sudo); owner=(-o "$CONTAINER_UID" -g "$CONTAINER_GID")
fi

run() {
  echo "+ $*"
  if (( apply )); then "$@"; fi
}

(( apply )) || echo "DRY RUN (no changes). Re-run with --apply."
echo "agent: $agent  data: $data${owner[*]+  owner: $CONTAINER_UID:$CONTAINER_GID}"

# ${arr[@]+"${arr[@]}"}: expands an empty array to nothing under `set -u` on bash 3.2 (macOS).
run ${as_root[@]+"${as_root[@]}"} install -d -m 700 ${owner[@]+"${owner[@]}"} "$data"

for f in config.yaml SOUL.md; do
  if [[ ! -f "$tpl/$f" ]]; then echo "skip $f: no template in agents/$agent/"; continue; fi
  # Dry-run never calls sudo (the dir is 700 and owned by the container UID); apply checks for real.
  if (( apply )) && ${as_root[@]+"${as_root[@]}"} test -e "$data/$f"; then
    echo "keep $f: already present in data dir"
  else
    (( apply )) || echo "(seeds $f only if absent)"
    run ${as_root[@]+"${as_root[@]}"} install -m 600 ${owner[@]+"${owner[@]}"} "$tpl/$f" "$data/$f"
  fi
done

if [[ ! -f "$tpl/SOUL.md" ]]; then
  echo "note: agents/$agent/SOUL.md missing. Write your own from the reference example:"
  echo "  cp examples/SOUL.example.md agents/$agent/SOUL.md  # then edit every <placeholder>"
fi

if [[ ! -f "$root/secrets/$agent.env" ]]; then
  echo "note: secrets/$agent.env missing. Create it with:"
  echo "  umask 077; install -m 600 secrets/$agent.env.example secrets/$agent.env  # then fill real values"
fi
