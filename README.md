# setup-sops-age

A Docker-based GitHub Action that installs pinned, checksum-verified `sops`
and `age`/`age-keygen` binaries and puts them on `$GITHUB_PATH`, so later
plain `run:` steps in the same job can use them with no further setup.

This replaces the pattern of every consuming repo separately
curl+checksum-installing `sops` (and, less commonly, `age`) itself.

## What's pinned

| Binary       | Version  | SHA-256                                                           | Source of the hash |
|--------------|----------|--------------------------------------------------------------------|---------------------|
| `sops`       | v3.13.3  | `e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b` | [getsops/sops's own published `checksums.txt`](https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.checksums.txt) for `sops-v3.13.3.linux.amd64` |
| `age`        | v1.3.2   | `cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10` | Computed locally from the real downloaded `age-v1.3.2-linux-amd64.tar.gz` release asset — age's releases carry no official checksums file, so this is a known, weaker-provenance pin (accepted for now) |
| `age-keygen` | v1.3.2   | (same tarball/hash as `age` above — both binaries ship in one archive) | — |

Bumping either pin is a manual step (no Dependabot here by choice, matching
the rest of this fleet's convention). To bump `sops`, pull the new version's
`checksums.txt` from its GitHub release and take the `linux.amd64` line. To
bump `age`, download the new version's `age-vX.Y.Z-linux-amd64.tar.gz`
release asset yourself and run `sha256sum` on it — there is no official
checksums file to source from instead.

## Usage

```yaml
- uses: sm-steel/setup-sops-age@<pinned-commit-sha> # v0.1.1
- run: |
    sops --version --disable-version-check
    age --version
    age-keygen --version
```

Pin `uses:` to the **commit SHA** of the release tag, not the floating tag
itself, per this fleet's usual third-party-action pinning convention.
Resolve it the same way every other pin in the fleet is resolved:

```bash
gh api repos/sm-steel/setup-sops-age/git/ref/tags/v0.1.1 --jq '.object.sha'
```

No login or extra secret is required to pull the underlying image: this
repo (and its GHCR package) are public, so `secrets.GITHUB_TOKEN`'s default
permissions are enough for any consumer, private or public. Verified for
real by consuming this action, pinned by commit SHA, from a completely
unrelated public scratch repo with no login step at all.

## How it works

- `Dockerfile` is a multi-stage build. The `build` stage downloads and
  checksum-verifies `sops` and `age`/`age-keygen`. The final stage is a
  plain `debian:bookworm-slim` (not distroless/scratch) — `entrypoint.sh`
  needs a real shell.
- `entrypoint.sh` runs as the whole `using: docker` step, and copies the
  three binaries out to a directory later `run:` steps (which execute
  directly on the runner, not inside this container) can see.
- `action.yml` references the built image by **digest**
  (`docker://ghcr.io/sm-steel/setup-sops-age@sha256:<digest>`), not by tag,
  so a consumer's pinned commit SHA is fully reproducible: the commit itself
  fixes exactly which image bytes run.

### The GITHUB_PATH gotcha (why args, not env vars)

The natural-looking approach — read `$RUNNER_TEMP` inside the container,
write files there, append that same value to `$GITHUB_PATH` — is broken.
Docker container actions get `RUNNER_TEMP`/`GITHUB_WORKSPACE` **translated**
to container-internal mount points (e.g. `/github/runner_temp`), which do
not exist on the runner itself once the container exits. This is a known,
documented gap in GitHub Actions
([community discussion #168949](https://github.com/orgs/community/discussions/168949)),
and it was caught here by hand during verification, not assumed away: v0.1.0
shipped with exactly this bug (`sops: command not found` in the very next
step) and was superseded by v0.1.1.

The fix `action.yml` uses: pass `${{ runner.temp }}` and
`${{ github.workspace }}` as plain CLI **args**. The runner evaluates those
expressions itself, on the host, *before* starting the container — so their
values are the real runner-side paths later steps will actually see.
`entrypoint.sh` uses those args (`$1`/`$2`) as the text it writes into
`GITHUB_PATH`, while still using the container-side `RUNNER_TEMP` env var to
physically write the files (same bind mount, different name from inside).

## Release procedure

`action.yml` must reference the image by digest, but that digest doesn't
exist until *after* a build — and the build happens from a commit that, at
push time, doesn't yet contain the resulting digest. This repo resolves that
chicken-and-egg with a two-commit release:

1. **Push the tag with a placeholder digest still in `action.yml`.**
   `git tag vX.Y.Z && git push origin vX.Y.Z`. `release.yml` fires, builds
   the image, and pushes `ghcr.io/sm-steel/setup-sops-age:X.Y.Z` — the run's
   job summary and `steps.build.outputs.digest` both carry the real digest.
2. **Read the real digest** from the finished run:
   ```bash
   gh run view <run-id> --repo sm-steel/setup-sops-age --log | grep 'Image pushed'
   # or:
   gh api repos/sm-steel/setup-sops-age/packages/container/setup-sops-age/versions \
     --jq '.[0].name'
   ```
3. **Commit the real digest into `action.yml`** on top of the same tagged
   commit (a new commit, not an amend).
4. **Move the tag** to that new commit — acceptable here since it's this
   repo's own release tag, not a third-party one:
   ```bash
   git tag -f vX.Y.Z
   git push -f origin vX.Y.Z
   ```
5. Re-resolve the tag's commit SHA (`gh api .../git/ref/tags/vX.Y.Z --jq
   '.object.sha'`) and use *that* SHA in any consumer's `uses:` line — the
   tag was moved, so a SHA resolved before step 4 is now stale.

Every future release (`v0.2.0`, `v1.0.0`, ...) follows the same five steps.

**Note on step 4's rebuild:** moving the tag re-triggers `release.yml`,
which rebuilds and re-pushes the image — and Docker image builds are not
byte-reproducible (the image config's embedded timestamp differs every
build even with identical inputs), so this second build's digest will
differ from the one just committed into `action.yml`. That's fine and
expected: `action.yml` pins a specific digest directly
(`@sha256:<digest>`), not the mutable `:X.Y.Z` image tag, and GHCR keeps a
digest's manifest pullable even after no tag points to it anymore (nothing
in this repo prunes untagged versions). Don't chase the tag-triggered
rebuild's new digest into another commit — the one already committed is the
real, final, pullable one.
