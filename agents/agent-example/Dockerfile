# agent-example image: the pinned Hermes Agent image plus the GitHub CLI (gh) and its token wrapper. Nothing else is added.
# Built locally by `docker compose build agent-example`; never pushed. Scan every rebuild (Trivy) before use.
# checkov:skip=CKV_DOCKER_2: started on demand by compose (restart "no"); no orchestrator consumes a healthcheck.

# Base: pinned by digest. On 2026-11-05 the tag v0.22.6 resolved to this digest in the registry. The base image
# carries its own OS packages, so expect scanner findings: review them and keep an explicit accepted-findings list.
FROM nousresearch/hermes-agent:v0.22.6@sha256:d27689bc6e8581ec884a7227c9101fdaebf6c853cff8859020dac14f21452b4d

# gh v2.103.3. SHA-256 from the official gh_2.103.3_checksums.txt (re-checked 2026-11-05).
# To upgrade: change both values, verify the checksum (and `gh attestation verify -R cli/cli`), rebuild, re-scan.
ARG GH_VERSION=2.103.3
ARG GH_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d

# The base image's default user is root (s6-overlay init); install as root, then switch below.
USER root
# Download, verify against the pinned hash (build fails on mismatch), install, clean up.
RUN set -eu; \
    tarball="gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "/tmp/${tarball}" \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"; \
    echo "${GH_SHA256}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xzf "/tmp/${tarball}" -C /tmp; \
    install -D -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/lib/gh/gh; \
    rm -rf "/tmp/${tarball}" "/tmp/gh_${GH_VERSION}_linux_amd64"; \
    /usr/local/lib/gh/gh --version

# gh on PATH is a wrapper that reads the token from the read-only file /etc/agent/github_token (compose secret),
# because Hermes strips GITHUB_TOKEN/GH_TOKEN from terminal commands. See gh-wrapper.sh.
COPY --chown=0:0 --chmod=0755 gh-wrapper.sh /usr/local/bin/gh

# Same non-root user compose sets (s6-overlay runs unprivileged; see compose.yaml /run tmpfs).
# ENTRYPOINT/CMD are unchanged from the base image.
USER 10000:10000
