# agent-example image: the pinned Hermes Agent image plus the GitHub CLI (gh) and its token wrapper. Nothing else is added.
# Built locally by `docker compose build agent-example`; never pushed. Scan every rebuild (Trivy) before use.
# checkov:skip=CKV_DOCKER_2: started on demand by compose (restart "no"); no orchestrator consumes a healthcheck.

# Base: pinned by digest. On 2026-11-05 the tag v0.22.6 resolved to this digest in the registry. The base image
# carries its own OS packages, so expect scanner findings: review them and keep an explicit accepted-findings list.
FROM nousresearch/hermes-agent:v0.23.1@sha256:276d44685c65c0cb2a25f190b63c65c8906f9dc76486fb1c05ae71b5826bda08

# gh v2.103.3. SHA-256 values from the official gh_2.103.3_checksums.txt (both architectures re-checked 2026-11-14).
# To upgrade: change the version and both hashes, verify the checksums (and `gh attestation verify -R cli/cli`), rebuild, re-scan.
ARG GH_VERSION=2.103.3
ARG GH_SHA256_AMD64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG GH_SHA256_ARM64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
# Set by BuildKit to the platform being built: amd64 on Intel/AMD hosts, arm64 on Apple Silicon. The base image
# is multi-arch, so the gh binary must match it. Without BuildKit this is empty and the build fails on purpose.
ARG TARGETARCH

# The base image's default user is root (s6-overlay init); install as root, then switch below.
USER root
# Pick the hash for this architecture, download, verify against it (build fails on mismatch), install, clean up.
RUN set -eu; \
    case "${TARGETARCH:-}" in \
      amd64) gh_sha256="${GH_SHA256_AMD64}" ;; \
      arm64) gh_sha256="${GH_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH '${TARGETARCH:-}': build with BuildKit for linux/amd64 or linux/arm64" >&2; exit 1 ;; \
    esac; \
    dir="gh_${GH_VERSION}_linux_${TARGETARCH}"; \
    tarball="${dir}.tar.gz"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "/tmp/${tarball}" \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}"; \
    echo "${gh_sha256}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xzf "/tmp/${tarball}" -C /tmp; \
    install -D -m 0755 "/tmp/${dir}/bin/gh" /usr/local/lib/gh/gh; \
    rm -rf "/tmp/${tarball}" "/tmp/${dir}"; \
    /usr/local/lib/gh/gh --version

# gh on PATH is a wrapper that reads the token from the read-only file /etc/agent/github_token (compose secret),
# because Hermes strips GITHUB_TOKEN/GH_TOKEN from terminal commands. See gh-wrapper.sh.
COPY --chown=0:0 --chmod=0755 gh-wrapper.sh /usr/local/bin/gh

# Same non-root user compose sets (s6-overlay runs unprivileged; see compose.yaml /run tmpfs).
# ENTRYPOINT/CMD are unchanged from the base image.
USER 10000:10000
