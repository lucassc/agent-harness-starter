#!/usr/bin/env bash
# Compare a Trivy JSON report with the agent's accepted-findings list (agents/<agent>/trivy-accepted.txt).
# Fails on any HIGH/CRITICAL finding (CVE ID + package) that is not listed; warns about listed entries that no
# longer appear, so the list shrinks when the base image is fixed. Nothing is suppressed in the report itself.
# Usage: scripts/check-trivy.sh <agent-name> <trivy-report.json>    (also: make scan-image)
set -euo pipefail
export LC_ALL=C

agent="${1:-}"; report="${2:-}"
[[ "$agent" =~ ^agent-[a-z0-9]+(-[a-z0-9]+)*$ && -f "$report" ]] \
  || { echo "usage: $0 <agent-name> <trivy-report.json>" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
accepted="$root/agents/$agent/trivy-accepted.txt"
[[ -f "$accepted" ]] || { echo "FAIL: $accepted missing" >&2; exit 1; }

found="$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")
                | "\(.VulnerabilityID) \(.PkgName)"' "$report" | sort -u)"
# Entry = first two fields of a non-comment line; everything after # is the reason.
listed="$(sed 's/#.*//' "$accepted" | awk 'NF >= 2 {print $1, $2}' | sort -u)"

new="$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$listed") | sed '/^$/d')"
gone="$(comm -13 <(printf '%s\n' "$found") <(printf '%s\n' "$listed") | sed '/^$/d')"
count() { [[ -n "$1" ]] && printf '%s\n' "$1" | wc -l || echo 0; }

echo "   HIGH/CRITICAL (CVE + package): $(count "$found") found, $(count "$listed") accepted," \
     "$(count "$new") new, $(count "$gone") no longer present"

if [[ -n "$gone" ]]; then
  echo "   No longer present (remove from $(basename "$accepted")):"
  printf '%s\n' "$gone" | sed 's/^/     /'
fi

if [[ -n "$new" ]]; then
  echo "   FAIL: not in the accepted list:"
  while read -r id pkg; do
    jq -r --arg id "$id" --arg pkg "$pkg" '[.Results[]?.Vulnerabilities[]?
        | select(.VulnerabilityID==$id and .PkgName==$pkg)][0]
        | "     \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) [\(.Severity)] fixed: \(.FixedVersion // "none") | \((.Title // "-")[0:90])"' "$report"
  done <<< "$new"
  echo "   Fix it (rebuild on a patched base) or accept it in $accepted with a reason, in a reviewed commit."
  exit 1
fi
echo "   ok"
