#!/usr/bin/env bash
# Invoked as: docker run --rm -v "<host-dir>:/out" ghcr.io/sm-steel/setup-sops-age@sha256:<digest>
#
# action.yml's composite step is the one that knows the real, runner-side
# path to bind-mount (it runs natively, not inside any container, so
# $RUNNER_TEMP there is the actual host path -- see action.yml and README's
# "GITHUB_PATH gotcha" section for why this indirection exists at all).
# This script's only job is to copy the baked-in, pinned+verified binaries
# into whatever got mounted at /out, and smoke-test them.
set -euo pipefail

mkdir -p /out
cp /usr/local/bin/sops /usr/local/bin/age /usr/local/bin/age-keygen /out/
chmod +x /out/sops /out/age /out/age-keygen

/out/sops --version --disable-version-check
/out/age --version
