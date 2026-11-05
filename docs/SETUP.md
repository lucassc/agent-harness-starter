# Setting up agent-example (Claude + Slack + GitHub)

`agent-example` is the technical ID used in files, paths and commands. Pick a display name of your own
for the Slack app and the GitHub user, so everyone can see it is an agent.

Status: **draft, untested end to end from this repository.** Items marked **VERIFY** were not confirmed in
the current Hermes docs or need a first-run test. Vendor UIs and docs change; re-check each detail before
relying on it.

agent-example is a Hermes Agent instance with the role you write in `agents/agent-example/SOUL.md`
(start from [examples/SOUL.example.md](../examples/SOUL.example.md)). It talks to you over Slack, uses a
Claude API key for its model, and uses its own GitHub identity to push branches and open pull requests.

```text
you ── Slack (Socket Mode, outbound only) ──┐
                                            ▼
          agent-example ──HTTPS_PROXY──▶ proxy-example (Squid allowlist) ──▶ api.anthropic.com
        (internal network only)                                         ├─▶ *.slack.com
                                                                        └─▶ github.com, api.github.com
```

Rules that apply throughout:

- Real secrets live **only** in `secrets/agent-example.env` and `secrets/agent-example.github_token`
  (gitignored). Never paste a token into chat, a prompt, a URL, a log, a commit or a screenshot. If one
  leaks, **rotate it** (section 6); rewriting git history is not enough.
- Never "fix" a failure by removing `cap_drop`, `read_only`, `no-new-privileges`, the egress allowlist or
  the approval gate. If a control must change, record why.
- Do not give the agent customer data, customer code or personal data. Use synthetic or redacted samples.

## 0. Prerequisites

- Docker with Compose v2, on a Linux host with disk encryption. Tested here with Compose v2.32.4.
- `sudo` (needed once to give the data dir to the container user), `jq` (the Trivy gate uses it).
- Scanners on your `PATH`: `gitleaks`, `checkov`, `semgrep`, `trivy`, `shellcheck`. Versions this was run
  with on 2026-11-05: gitleaks 8.30.1, checkov 3.3.29, semgrep 1.181.0, trivy 0.76.2, shellcheck 0.11.0.
- Admin rights on the Slack workspace (or an admin who approves apps) and on the GitHub account or org.
- Image digests are pinned in [compose.yaml](../compose.yaml) and the Dockerfile. Re-check them against the
  registry (`docker buildx imagetools inspect <image>:<tag>`) and re-scan before each upgrade.

## 1. Claude (model key)

1. Open the Anthropic Console and create a **separate workspace** for this agent if your account supports
   workspaces (**VERIFY** the current Console UI).
2. Set a **monthly spend limit** on that workspace, as low as the job allows.
3. Create an API key in that workspace named `agent-example`. Use a Console API key only: never your main
   key, a key shared with another tool, or a Claude Code / claude.ai OAuth token.
4. Put it in `secrets/agent-example.env` as `ANTHROPIC_API_KEY` (**VERIFY** the variable name and how
   Hermes selects the provider: the Hermes docs say `hermes model` switches it, and `config.yaml` may need
   a model entry).
5. The key is readable by the agent. That is why it must be scoped, capped and revocable.

Privacy: prompts and file contents go to Anthropic's API, which may be processing outside your country.
Check current terms, disclose it, and keep customer data out.

## 2. Slack app

Hermes uses **Socket Mode** (outbound WebSocket): no public URL, nothing listens on your host.

1. At `api.slack.com/apps` choose **Create New App → From a manifest** (or build it by hand) and give it
   your agent's display name. Hermes can print a manifest with `hermes slack manifest` (**VERIFY**: run it as
   `docker compose run --rm --no-deps agent-example slack manifest` once you are willing to run the image).
2. **Socket Mode:** enable it and create an **app-level token** with scope `connections:write` (`xapp-…`).
3. **App Home:** enable the **Messages Tab**, or Slack blocks DMs to the bot.
4. **Bot token scopes** (`xoxb-…`):
   - Hermes docs list as required: `chat:write`, `app_mentions:read`, `channels:history`, `channels:read`,
     `groups:history`, `im:history`, `im:read`, `im:write`, `mpim:history`, `mpim:read`, `users:read`,
     `files:read`, `files:write`. Check this against the current docs.
   - Least-privilege start (DM only): `chat:write`, `im:history`, `im:read`, `im:write`, `users:read`. Add
     more only if Hermes reports a missing scope (**VERIFY** that this subset works). Skip `files:write`
     unless you need uploads.
5. **Event subscriptions:** `message.im` (DM-only start). Full channel use needs `message.channels`,
   `message.mpim`, `app_mention`; add `message.groups` for private channels.
6. **Install** the app to the workspace. Changing scopes or events later requires **reinstalling**.
7. Find your **Member ID** (profile → ⋮ → Copy member ID, looks like `U01ABC2DEF3`).
8. In `secrets/agent-example.env` set `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` and
   `SLACK_ALLOWED_USERS=<your-member-id>`.

Behaviour you get:

- `SLACK_ALLOWED_USERS` unset = everyone denied. Only listed IDs can talk to the agent.
- DMs are answered without a mention; in channels it answers only when @mentioned (`require_mention: true`).
- Strangers who DM the bot are ignored (`unauthorized_dm_behavior: "ignore"` in
  [config.yaml](../agents/agent-example/config.yaml) and the managed config).
- Do not set `SLACK_ALLOW_BOTS`, `SLACK_ALLOW_ALL_USERS` or `GATEWAY_ALLOW_ALL_USERS`.

Privacy: Slack stores the conversation. It is a subprocessor; confirm its current terms and regions.

## 3. GitHub identity (own user, one repository)

This is a **deliberate exception** to "read-only first": the agent needs to push branches and open pull
requests. You must decide it knowingly. Choose between:

- **Machine user** (simpler): a separate GitHub account for the agent. It needs its own email and 2FA, and
  may take a paid seat (**VERIFY** GitHub's current terms for machine accounts).
- **GitHub App** (better isolation: short-lived, per-repository tokens, no seat). It needs token-minting
  code that this repository does not have.

The rest of this section describes the machine-user path with a fine-grained token.

1. Create the account with a dedicated mailbox, enable 2FA, and store its recovery codes in your secret
   manager. The profile should say it is an AI agent (check GitHub's current rules for machine accounts).
   The mailbox must stay in human hands: no mailbox credentials or 2FA seed for the agent.
2. Give it access to the **one** repository it needs, as a direct collaborator with write. If you grant
   write through a **team** instead, the agent gets write on **every repository later added to that team**.
   Before adding a repository to such a team, make sure its ruleset requires an approval (see "Branch
   protection" below). Read-only check for a team (replace `ORG` and `TEAM`):
   ```bash
   gh api orgs/ORG/teams/TEAM/repos --jq '.[] | select(.permissions.push) | .name' \
     | while read -r r; do printf '%s approvals=' "$r"; gh api "repos/ORG/$r/rules/branches/main" \
       --jq '[.[] | select(.type=="pull_request") | .parameters.required_approving_review_count] | max // "NONE"'; done
   ```
   Every line must show `approvals=1` or more.
3. If the account is in an org, check the org allows fine-grained tokens and approve the token request if
   approval is required. Otherwise the token sees no repositories.
4. As the machine user, create a **fine-grained token** with the repository list limited to the
   repositories it needs, and a short expiry (for example 30 to 90 days):
   - Grant: **Contents** read+write, **Pull requests** read+write, **Issues** read, **Actions** read,
     **Metadata** read.
   - **Actions: read** lets the agent read CI job logs (`gh run view --log-failed`). The agent never builds
     in its own container; CI does. The log download redirects to
     `results-receiver.actions.githubusercontent.com`, which is on the proxy allowlist for that reason
     (exact host). `gh pr checks` needed a permission that fine-grained tokens did not give in testing;
     use `gh run` instead (**VERIFY** against current GitHub behaviour).
   - Do **not** grant: Workflows, Actions write, Administration, Secrets, Environments, Webhooks. Without
     Workflows the agent cannot push changes to `.github/workflows/`.
5. Put the token in its **own file**, not in the env file: Hermes strips `GITHUB_TOKEN`/`GH_TOKEN` from every
   terminal command, so an env var never reaches `gh`. Compose mounts the file read-only at
   `/etc/agent/github_token`; the `gh` on the image's PATH is a wrapper
   ([gh-wrapper.sh](../agents/agent-example/gh-wrapper.sh)) that reads it for that one process, and `git`
   gets it from `gh` through a credential helper set by `GIT_CONFIG_*` in `compose.yaml`, so the token is
   never in a clone URL. Compose ignores `uid`/`gid`/`mode` for file secrets, so the host file itself must
   belong to the container user (needs sudo):
   ```bash
   umask 077
   $EDITOR secrets/agent-example.github_token        # the token only, one line
   sudo chown 10000:10000 secrets/agent-example.github_token
   sudo chmod 0400 secrets/agent-example.github_token
   ```
   To rotate it later: `sudo install -o 10000 -g 10000 -m 0400 <new-file> secrets/agent-example.github_token`,
   then delete `<new-file>`. No restart is needed (the wrapper reads the file on every call).
6. Set the commit identity with `GIT_AUTHOR_*`/`GIT_COMMITTER_*` in `compose.yaml` (the placeholder is
   `agent@example.invalid`). Signed commits are not configured (the agent has no signing key); do not
   require them on the repository.

**Branch protection is the real control.** The token cannot be limited to certain branches, and the Hermes
approval gate is a heuristic, not containment. With Contents and Pull requests write, the token **can
merge a PR** unless a ruleset requires an approval the agent cannot give itself. Every repository in the
token must therefore have, on its default branch: at least **1 required approval**, required checks, and
no bypass for the machine user. Read-only check, for each repository in the token (replace `OWNER` and
`REPO`):

```bash
gh api "repos/OWNER/REPO/rules/branches/main" \
  --jq '.[] | select(.type=="pull_request" or .type=="required_status_checks") | {type, approvals: .parameters.required_approving_review_count}'
```

`approvals` must be 1 or more. Also check how CI and preview deploys trigger on a pushed branch. If a branch
push runs with secrets or deploys automatically, a prompt-injected agent could abuse it; fix that before
granting write.

**Builds run in CI, never in the agent.** No package registry is on the allowlist and no package manager is
in the image. Build-time code would run as the agent's UID, which can read the Hermes process environment
(API and Slack keys) and the GitHub token file. Squid only sees `CONNECT registry.example.org`, so it cannot
block a publish as an exfiltration path. Let CI build every PR in a throwaway runner, and have the agent
read the result with `gh run`.

## 4. Prepare the host (each step needs your explicit yes)

```bash
cd agent-harness-starter

# 1. Scan the repo (no network except rule downloads): gitleaks on committable files and history,
#    shellcheck, semgrep, checkov on the Dockerfiles, compose syntax. Same as: make lint
scripts/lint.sh

# 2. Create the data dir for the container user (UID 10000, mode 700). Dry-run first.
scripts/init-dirs.sh agent-example
scripts/init-dirs.sh --apply agent-example        # uses sudo

# 3. Create the real env file, then edit it (do not paste secrets into chat)
umask 077
install -m 600 secrets/agent-example.env.example secrets/agent-example.env
$EDITOR secrets/agent-example.env                 # ANTHROPIC_API_KEY, SLACK_* (GitHub token: own file, section 3 step 5)
stat -c '%a %n' secrets/agent-example.env         # must print 600
```

`scripts/lint.sh` skips its `docker compose config` step until the two secret files exist; run it again
after step 3 and section 3 step 5.

## 5. First run

Short form: `make up` (build, Trivy against `agents/<agent>/trivy-accepted.txt`, start proxy then agent,
both checks), `make check` after any restart, `make stop` when done; `make help` lists the rest. The
Makefile only wraps the commands below, which stay the reference.

The Trivy gate **will probably fail on the first run**: the pinned base image carries OS packages with
known HIGH or CRITICAL findings, and `trivy-accepted.txt` starts empty. For each finding either rebuild on
a patched base, or accept it in that file with a written reason, in a reviewed commit. Do not accept in bulk.

```bash
# Build the agent image (pinned Hermes base + pinned, checksum-verified gh), then scan it
docker compose build agent-example
trivy image --scanners vuln --severity HIGH,CRITICAL localhost/example/hermes-agent-example:v0.22.6-gh2.103.3

# Show what would be created before creating it
docker compose config -q && docker compose up --dry-run

# Start the proxy first, then the agent
docker compose up -d proxy-example
docker compose up -d agent-example
docker compose ps
docker compose logs -f agent-example              # look for the Slack connection; Ctrl-C to stop following

# Both must print RESULT: PASS before you trust the agent (run them after every restart too)
scripts/check-egress.sh --run agent-example       # egress allowlist
EXPECT_GH_LOGIN=<machine-user-login> scripts/check-config.sh --run agent-example   # managed config in force
```

Without `EXPECT_GH_LOGIN`, the check that the agent authenticates as the right GitHub user is skipped and
says so.

Model, approvals, Slack options and the toolset allowlist live in
[managed-config.yaml](../agents/agent-example/managed-config.yaml), mounted read-only at
`/etc/hermes/config.yaml`. Change them there (not with `hermes config set`, which refuses managed keys),
recreate the agent and re-run `check-config.sh`. Keep the expected values in `check-config.sh` in sync.

Then:

1. DM the Slack app from your account. You should get a reply.
2. Ask for a harmless action that needs approval and confirm you can approve or deny it. How approvals
   reach you over Slack is **VERIFY**; the timeout is fail-closed (no answer = denied).
3. Read the proxy log to see what the agent really contacts:
   ```bash
   docker compose logs proxy-example | grep -E 'TCP_(DENIED|TUNNEL)'
   ```
   Add a host to [proxy/squid-agent-example.conf](../proxy/squid-agent-example.conf) only after you
   understand why it is needed. Apply it with `make up`: the config is a single-file mount, so
   `squid -k reconfigure` still reads the old copy; the proxy must be recreated, and Compose stops the
   agent when it recreates the proxy, so start both and re-run the checks. Tighten `.slack.com` to the
   hosts you actually see.
4. Ask it to clone your repository and open a draft PR from a new branch. Confirm the PR needs human review
   and that it cannot push to the default branch.

Stop it when you are not using it: `docker compose stop` (restart policy is `"no"`).

## 6. Rotation, incidents and deletion

- **Suspected leak** of any token: revoke it at the provider first (Console key, Slack app tokens →
  regenerate/reinstall, GitHub token → delete), then update `secrets/agent-example.env` (or
  `secrets/agent-example.github_token`), then restart. Check provider usage logs for the exposure window.
- **Delete the agent's state** (sessions, memory, logs, stored credentials). Dry-run first:
  ```bash
  docker compose stop agent-example
  scripts/wipe-agent.sh agent-example
  scripts/wipe-agent.sh --apply --yes agent-example
  ```
  This does not delete data held by Anthropic, Slack or GitHub; revoke the agent's keys and handle those
  through each provider.
- **Retention:** `data/agent-example/` holds sessions, memory, logs and possibly credentials. Keep disk
  encryption on, never back it up to shared locations, and agree a retention period.

## 7. Troubleshooting

| Symptom | Likely cause | What to do (without removing a control) |
| --- | --- | --- |
| Container exits at start | s6 `/run belongs to uid 0` or `exec: .../init: Permission denied` | The `/run` tmpfs must be owned by 10000 and mounted `exec` (already set in `compose.yaml`). No caps need adding back. |
| Read-only filesystem errors | A path needs to be writable | Add that exact path as a tmpfs or volume in `compose.yaml`; keep `read_only: true`. |
| No Slack connection, no proxy log line | Hermes' Slack client may ignore `HTTPS_PROXY` (fails closed) | Look for a Hermes proxy setting for Slack (**VERIFY**). Do not give the agent direct internet access. |
| `403` in the proxy log for a host | Not in the allowlist | Decide whether it is needed, then add it. |
| `invalid_auth` / `not_allowed_token_type` from Slack | Wrong or swapped token | Bot token is `xoxb-`, app token is `xapp-`. |
| Slack ignores your DM | Your Member ID is missing from `SLACK_ALLOWED_USERS` | Fix the env file and restart. |
| Git push rejected | Branch protection (expected) or missing token scope | Open a PR from a branch; do not widen the token. |
| TLS handshakes hang through the proxy on a VPN | MTU mismatch (`compose.yaml` sets the egress network to 1280) | Lower the MTU further if your VPN needs it. |
| `docker pull`/Trivy 401 or 429 | Stale Docker Hub login or anonymous rate limit | `docker logout && docker login`, or scan with an empty `DOCKER_CONFIG`. |
| SQLite errors on macOS/Windows bind mounts | virtiofs/9p | Use a named volume or set `database.journal_mode: delete` (**VERIFY**). |

## 8. Known gaps

- DNS: Docker's resolver on the internal network may still resolve external names, which is a possible
  exfiltration channel.
- The proxy sees hostnames, not content. Anything sent to an allowed host (Anthropic, Slack, GitHub) passes
  through.
- The pinned Hermes image carries OS packages with HIGH and CRITICAL findings; some may have no fixed
  version yet. Re-scan on every upgrade and record decisions in `trivy-accepted.txt`.
- The scanners (Gitleaks, Semgrep, Trivy, Checkov) are not in the agent image; run them on your side or in CI.
- Compose files have no Checkov/Trivy coverage, so `compose.yaml` hardening is reviewed by hand plus Semgrep.
- Whether Hermes honours the proxy variables for every outbound path (Slack client, model client, browser
  tools) is unverified. `check-egress.sh` tests curl only; watch Squid's access log for the rest.
