#!/bin/sh
# /usr/local/bin/gh in the agent-example image: hands the GitHub token to the real gh for this one process.
# Why: Hermes strips GITHUB_TOKEN/GH_TOKEN from every terminal command (Tier-1 secrets, not re-allowable via
# terminal.env_passthrough), so the token comes from a read-only file mounted by compose instead of the env.
# The token is exported only into gh's own environment; it is never printed, logged or written elsewhere.
# git gets it too, because git's credential helper for github.com is `gh auth git-credential` (compose.yaml).
set -eu

token_file=/etc/agent/github_token
real_gh=/usr/local/lib/gh/gh

if [ -z "${GH_TOKEN:-}" ] && [ -r "$token_file" ]; then
  GH_TOKEN="$(cat "$token_file")"
  export GH_TOKEN
fi

exec "$real_gh" "$@"
