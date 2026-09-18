#!/usr/bin/env bash
# Runs *inside* the setup-sops-age container as this action's whole "using:
# docker" step. GitHub Actions bind-mounts RUNNER_TEMP/GITHUB_WORKSPACE (and
# passes their paths through as env vars) into the container at the same
# paths they have on the actual runner -- so anything this script writes
# under $RUNNER_TEMP is still there, at the same path, once the container
# exits and later plain `run:` steps execute directly on the runner.
set -euo pipefail

DEST_ROOT="${RUNNER_TEMP:-${GITHUB_WORKSPACE:-/tmp}}"
DEST="${DEST_ROOT}/setup-sops-age-bin"
mkdir -p "${DEST}"

cp /usr/local/bin/sops "${DEST}/sops"
cp /usr/local/bin/age "${DEST}/age"
cp /usr/local/bin/age-keygen "${DEST}/age-keygen"
chmod +x "${DEST}/sops" "${DEST}/age" "${DEST}/age-keygen"

echo "${DEST}" >> "${GITHUB_PATH}"

echo "setup-sops-age: installed to ${DEST} and appended to GITHUB_PATH"

# Smoke check -- exercise the copies that later steps will actually run.
"${DEST}/sops" --version --disable-version-check
"${DEST}/age" --version
