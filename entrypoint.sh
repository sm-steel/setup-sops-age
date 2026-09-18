#!/usr/bin/env bash
# Runs *inside* the setup-sops-age container as this action's whole "using:
# docker" step.
#
# Docker container actions get RUNNER_TEMP/GITHUB_WORKSPACE translated to
# container-internal mount points (e.g. /github/runner_temp), which do NOT
# exist on the actual runner once this container exits -- a documented gap
# (see github.com/orgs/community/discussions/168949), confirmed by hand
# while building this action: writing that container-side path into
# GITHUB_PATH breaks every later `run:` step with "command not found".
#
# The fix: action.yml passes ${{ runner.temp }} / ${{ github.workspace }}
# as plain CLI args ($1/$2). The runner evaluates those expressions itself,
# on the HOST, *before* starting this container, so their values are the
# real runner-side paths later `run:` steps will actually see -- exactly
# the string GITHUB_PATH needs. We still use the container-side
# RUNNER_TEMP/GITHUB_WORKSPACE env vars to physically write the files,
# since (being the same bind mount, just under a different name in here)
# that's what makes them show up at the host path at all.
set -euo pipefail

HOST_RUNNER_TEMP="${1:-}"
HOST_GITHUB_WORKSPACE="${2:-}"
HOST_DEST_ROOT="${HOST_RUNNER_TEMP:-${HOST_GITHUB_WORKSPACE:-/tmp}}"

CONTAINER_DEST_ROOT="${RUNNER_TEMP:-${GITHUB_WORKSPACE:-/tmp}}"
CONTAINER_DEST="${CONTAINER_DEST_ROOT}/setup-sops-age-bin"
HOST_DEST="${HOST_DEST_ROOT}/setup-sops-age-bin"

mkdir -p "${CONTAINER_DEST}"
cp /usr/local/bin/sops "${CONTAINER_DEST}/sops"
cp /usr/local/bin/age "${CONTAINER_DEST}/age"
cp /usr/local/bin/age-keygen "${CONTAINER_DEST}/age-keygen"
chmod +x "${CONTAINER_DEST}/sops" "${CONTAINER_DEST}/age" "${CONTAINER_DEST}/age-keygen"

echo "${HOST_DEST}" >> "${GITHUB_PATH}"

echo "setup-sops-age: installed to ${HOST_DEST} (as seen from the runner) and appended to GITHUB_PATH"

# Smoke check -- exercise the container-local copies (the host-side path
# isn't runnable from inside this container; it's only valid once we exit).
"${CONTAINER_DEST}/sops" --version --disable-version-check
"${CONTAINER_DEST}/age" --version
