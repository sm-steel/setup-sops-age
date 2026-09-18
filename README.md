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
- uses: sm-steel/setup-sops-age@<pinned-commit-sha> # v0.1.0
- run: |
    sops --version --disable-version-check
    age --version
    age-keygen --version
```

Pin `uses:` to the **commit SHA** of the release tag, not the floating tag
itself, per this fleet's usual third-party-action pinning convention.
Resolve it the same way every other pin in the fleet is resolved:

```bash
gh api repos/sm-steel/setup-sops-age/git/ref/tags/v0.1.0 --jq '.object.sha'
```

No login or extra secret is required to pull the underlying image: this
repo (and its GHCR package) are public, so `secrets.GITHUB_TOKEN`'s default
permissions are enough for any consumer, private or public.

## How it works

- `Dockerfile` is a multi-stage build. The `build` stage downloads and
  checksum-verifies `sops` and `age`/`age-keygen`. The final stage is a
  plain `debian:bookworm-slim` (not distroless/scratch) — `entrypoint.sh`
  needs a real shell.
- `entrypoint.sh` runs as the whole `using: docker` step. GitHub Actions
  bind-mounts `RUNNER_TEMP` (falling back to `GITHUB_WORKSPACE`) into the
  container at the same path it has on the runner, so copying the binaries
  there — then appending that path to `$GITHUB_PATH` — makes them usable by
  later `run:` steps in the *same job*, which execute directly on the
  runner, not inside this container.
- `action.yml` references the built image by **digest**
  (`docker://ghcr.io/sm-steel/setup-sops-age@sha256:<digest>`), not by tag,
  so a consumer's pinned commit SHA is fully reproducible: the commit itself
  fixes exactly which image bytes run.

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
