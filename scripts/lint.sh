#!/usr/bin/env bash
# Static checks on this repo. Read-only: nothing is changed, nothing is started, no secret is printed.
# Usage: scripts/lint.sh            (also: make lint)
# Needs gitleaks, shellcheck, semgrep, checkov and docker on PATH (docs/SETUP.md, added in a later change).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
fail=0

step() {
  local desc="$1"; shift
  echo "== $desc"
  if "$@"; then echo "   ok"; else echo "   FAIL"; fail=1; fi
}

# Gitleaks on exactly what git would commit: tracked plus untracked-but-not-ignored files.
# secrets/*.env, secrets/*.github_token and data/ hold real secrets by design; they are gitignored and
# never committed, so they are out of scope here (scanning them only reports the secrets we put there).
gitleaks_committable() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do [[ -f "$f" ]] && printf '%s\0' "$f"; done \
    | xargs -0 -r cp --parents -t "$tmp" --
  gitleaks dir "$tmp" --redact --no-banner --log-level warn || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

step "gitleaks: committable files" gitleaks_committable
step "gitleaks: git history" gitleaks git . --redact --no-banner --log-level warn
step "shellcheck" shellcheck scripts/*.sh agents/*/*.sh
# Semgrep honours .gitignore, so secrets/ and data/ are skipped.
step "semgrep" semgrep scan --metrics=off --error --quiet \
  --config p/secrets --config p/docker-compose --config p/command-injection .
for dockerfile in agents/*/Dockerfile; do
  step "checkov: $dockerfile" checkov -f "$dockerfile" --compact --quiet
done
# Checkov and Trivy do not cover Compose files; this only validates syntax and interpolation.
# It needs the secret files that compose.yaml references. A fresh clone has none, so it is skipped with a note.
if [[ -f secrets/agent-example.env && -f secrets/agent-example.github_token ]]; then
  step "docker compose config" docker compose -f "$root/compose.yaml" config -q
else
  echo "== docker compose config"
  echo "   SKIPPED: secrets/agent-example.env or .github_token missing (create them first, see docs/SETUP.md)"
fi

if (( fail )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
