# Multi-stage: the build stage downloads and checksum-verifies sops and
# age/age-keygen; the run stage is a plain debian:bookworm-slim (not
# distroless/scratch) because entrypoint.sh needs a real shell to copy the
# binaries out to the runner and append to $GITHUB_PATH.

FROM debian:bookworm-slim AS build

# sops: version + SHA-256 sourced from getsops/sops's own published
# checksums.txt release asset (not computed locally). To bump:
#   gh release download vX.Y.Z --repo getsops/sops \
#     --pattern 'sops-vX.Y.Z.checksums.txt' --output -
# and take the line for sops-vX.Y.Z.linux.amd64.
ARG SOPS_VERSION=v3.13.3
ARG SOPS_SHA256=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b

# age + age-keygen: age's GitHub releases carry no official checksums.txt
# (confirmed gap, not an oversight) -- this hash was computed locally from a
# real downloaded release asset:
#   curl -fsSL -o age.tar.gz \
#     https://github.com/FiloSottile/age/releases/download/vX.Y.Z/age-vX.Y.Z-linux-amd64.tar.gz
#   sha256sum age.tar.gz
# Weaker provenance than sops's pin above; accepted for now.
ARG AGE_VERSION=v1.3.2
ARG AGE_SHA256=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/sops \
      "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
    && echo "${SOPS_SHA256}  /tmp/sops" | sha256sum -c - \
    && install -m 0755 /tmp/sops /usr/local/bin/sops

RUN curl -fsSL -o /tmp/age.tar.gz \
      "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
    && echo "${AGE_SHA256}  /tmp/age.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/age.tar.gz -C /tmp \
    && install -m 0755 /tmp/age/age /usr/local/bin/age \
    && install -m 0755 /tmp/age/age-keygen /usr/local/bin/age-keygen

FROM debian:bookworm-slim

COPY --from=build /usr/local/bin/sops /usr/local/bin/sops
COPY --from=build /usr/local/bin/age /usr/local/bin/age
COPY --from=build /usr/local/bin/age-keygen /usr/local/bin/age-keygen
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/sops /usr/local/bin/age /usr/local/bin/age-keygen

ENTRYPOINT ["/entrypoint.sh"]
