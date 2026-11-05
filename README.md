# agent-harness-starter

A starter for running a coding agent with least-privilege defaults: one container for the agent, one
allowlist proxy in front of it, secrets kept out of the environment, and checks that tell you whether
the controls are really in force.

It runs a [Hermes Agent](https://github.com/NousResearch/hermes-agent) instance that talks to you over
Slack, uses an Anthropic API key for its model, and uses its own GitHub identity to open pull requests.
It is a **starting point to read, change and review**, not a finished product and not a security
guarantee.

## Status

**Early and unproven in this repository.** The setup it was derived from ran locally once. This starter
has not been run end to end:

- Passes `make lint` (Gitleaks, ShellCheck, Semgrep, Checkov on the Dockerfile) and `docker compose config`.
- The image has **not** been built or scanned from this repository. Run `make scan-image` yourself.
- Slack, the approval flow and the GitHub flow are untested here. Items marked **VERIFY** in the files
  were not confirmed against current Hermes docs.
- Generated and copied files are unreviewed until a human has read them. Review before you rely on them.

Pinned image digests and the `gh` checksum were checked against their upstream sources on 2026-11-05.
Tags move, so re-check before use.

## How it fits together

```text
you ── Slack (Socket Mode, outbound only) ──┐
                                            ▼
          agent-example ──HTTPS_PROXY──▶ proxy-example (Squid allowlist) ──▶ api.anthropic.com
        (internal network only)                                         ├─▶ *.slack.com
                                                                        └─▶ github.com, api.github.com
```

What the defaults do:

- **No direct internet for the agent.** It sits on an `internal` Docker network. Only the proxy can reach
  out, and only to the hosts in [proxy/squid-agent-example.conf](proxy/squid-agent-example.conf).
- **Locked-down containers:** non-root user, `cap_drop: ALL`, `read_only`, `no-new-privileges`, no ports
  published, memory and PID limits.
- **Config the agent cannot change.** Model, approvals and the toolset allowlist are mounted read-only
  ([managed-config.yaml](agents/agent-example/managed-config.yaml)). Approvals are `manual` and fail closed.
- **The GitHub token is a read-only file, not an environment variable**, read by a small `gh` wrapper.
- **Checks you can run:** `check-egress.sh` (what the agent can and cannot reach), `check-config.sh`
  (is the managed config in force; Hermes fails open without it) and a Trivy gate that fails on image
  findings you have not reviewed.

What it does **not** do, so you are not surprised:

- The proxy sees hostnames, not content. Anything sent to an allowed host passes through.
- Docker's DNS on the internal network may still resolve external names, a possible exfiltration channel.
- The agent can read its own secrets. That is why keys must be scoped, spend-capped and revocable.
- Branch protection on the target repository is the real control against the agent merging its own work.
  The token cannot enforce it. See [docs/SETUP.md](docs/SETUP.md) section 3.

## Quick start

Needs Docker with Compose v2, `sudo` (once, for the data dir), `jq`, and the scanners listed in
[docs/SETUP.md](docs/SETUP.md). The full walkthrough, including the Anthropic, Slack and GitHub setup,
is there. Every step that writes something has a dry run first.

```bash
make help                      # list targets
make lint                      # static checks
make init                      # dry run: show how the data dir would be created
make init-apply                # create it for UID 10000, mode 700 (asks for sudo)
umask 077
install -m 600 secrets/agent-example.env.example secrets/agent-example.env   # then fill in real values
# put the GitHub token in secrets/agent-example.github_token (see docs/SETUP.md section 3)
make up                        # build, scan, start proxy then agent, run both checks
make stop
```

## Layout

```text
compose.yaml                         agent + allowlist proxy (no host ports published)
proxy/squid-agent-example.conf       deny-by-default CONNECT allowlist: Anthropic, Slack, GitHub
agents/agent-example/Dockerfile      pinned Hermes base + pinned, checksum-verified gh (built locally, never pushed)
agents/agent-example/managed-config.yaml   read-only config: model, approvals, Slack options, toolsets
agents/agent-example/config.yaml     seed config copied into the data dir
agents/agent-example/gh-wrapper.sh   gh on PATH: reads the token from the read-only secret file
agents/agent-example/trivy-accepted.txt    reviewed, accepted image findings (starts empty)
secrets/*.example                    placeholders; real *.env and *.github_token are gitignored
scripts/                             init-dirs, wipe-agent, check-egress, check-config, check-trivy, lint
examples/SOUL.example.md             reference example of an agent "soul" file; adapt it, do not copy it blindly
docs/SETUP.md                        step-by-step setup, rotation, deletion, troubleshooting
data/                                gitignored per-agent state (contains credentials; mode 700)
```

Give your agent a role by writing `agents/agent-example/SOUL.md` (start from
[examples/SOUL.example.md](examples/SOUL.example.md)) and re-running `make init-apply`.

## Adding another agent

Copy the `agent-example` blocks in `compose.yaml` (service, proxy, two networks, secret), the proxy conf,
the env example and `agents/agent-example/`, rename them, and add the name to `AGENTS` in the
[Makefile](Makefile). Never share one data directory between two containers.

## Privacy

This repository contains no personal data. A running agent does: prompts and file contents go to
Anthropic, conversations are stored by Slack, and repository content passes through GitHub. Each may
process data outside your country, which data protection law (GDPR and LGPD, for example) may treat as
an international transfer that you must disclose. Confirm each provider's current terms; do not assume.

- Do not give the agent customer data, credentials or personal data. Use synthetic or redacted samples.
- `data/<agent>/` holds sessions, memory and logs, and possibly credentials. Keep disk encryption on and
  decide a retention period. `scripts/wipe-agent.sh` deletes it. It does not delete data held by providers.
- Legal conclusions (legal basis, transfers) come from your lawyer or data protection officer, not from this repo.

## Contributing and security

This is a personal project shared as is. Issues and pull requests are welcome, but there is no support
or response-time commitment. To report a security problem, open a private security advisory on GitHub
rather than a public issue. Never include real tokens in an issue or pull request.

## License

[Apache License 2.0](LICENSE).
