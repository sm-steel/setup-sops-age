# setup-sops-age

A GitHub Action, backed by a Docker image that bakes in pinned,
checksum-verified `sops` and `age`/`age-keygen` binaries, that puts them on
`$GITHUB_PATH` so later plain `run:` steps in the same job can use them with
no further setup.

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
- uses: sm-steel/setup-sops-age@<pinned-commit-sha> # v0.1.2
- run: |
    sops --version --disable-version-check
    age --version
    age-keygen --version
```

Pin `uses:` to the **commit SHA** of the release tag, not the floating tag
itself, per this fleet's usual third-party-action pinning convention.
Resolve it the same way every other pin in the fleet is resolved:

```bash
gh api repos/sm-steel/setup-sops-age/git/ref/tags/v0.1.2 --jq '.object.sha'
```

No login or extra secret is required to pull the underlying image: this
repo (and its GHCR package) are public, so `secrets.GITHUB_TOKEN`'s default
permissions (or even no token at all) are enough for any consumer, private
or public. Verified for real by consuming this action, pinned by commit
SHA, from a completely unrelated public scratch repo with no login step at
all.

## How it works

- `Dockerfile` is a multi-stage build. The `build` stage downloads and
  checksum-verifies `sops` and `age`/`age-keygen`. The final stage is a
  plain `debian:bookworm-slim` (not distroless/scratch) — `entrypoint.sh`
  needs a real shell.
- `entrypoint.sh` is the image's `ENTRYPOINT`. It just copies the three
  baked-in binaries to `/out` (wherever the caller bind-mounted) and
  smoke-tests them.
- `action.yml` is a **composite** action with one `run:` step (see below for
  why it's `using: composite`, not `using: docker`). That step resolves the
  real runner-side temp directory, bind-mounts it into the pinned
  `setup-sops-age` image at `/out`, runs the image (which copies the
  binaries into that mount), and appends the directory to `$GITHUB_PATH`.
- The image itself is still referenced by **digest**
  (`ghcr.io/sm-steel/setup-sops-age@sha256:<digest>`), not by tag, so a
  consumer's pinned commit SHA is fully reproducible: the commit itself
  fixes exactly which image bytes run.

### The GITHUB_PATH gotcha (why composite, not `using: docker`)

The obvious design — make this a plain `using: docker` action whose
`entrypoint.sh` reads `$RUNNER_TEMP`, writes files there, and appends that
same value to `$GITHUB_PATH` — does not work, for two independent, both
empirically-confirmed reasons:

1. **A Docker container action's own `action.yml` has no access to the
   `github`/`runner` context at all.** Passing `${{ runner.temp }}` /
   `${{ github.workspace }}` as `runs.args` fails at parse time with
   `Unrecognized named-value: 'runner'` / `'github'` — before the container
   even starts.
2. **Even if it did**, `RUNNER_TEMP`/`GITHUB_WORKSPACE` *inside* a running
   Docker container action are translated to container-internal mount
   points (e.g. `/github/runner_temp`), which don't exist on the runner
   itself once the container exits. Writing that translated path into
   `GITHUB_PATH` breaks every later `run:` step with "command not found".

Both are known, documented gaps in GitHub Actions, not something specific
to this repo — see
[actions/runner#2522](https://github.com/actions/runner/issues/2522) and
[community discussion #168949](https://github.com/orgs/community/discussions/168949).
They were caught here by hand during verification, not assumed away:

- **v0.1.0** shipped as a pure `using: docker` action reading
  `$RUNNER_TEMP` directly — hit gap 2 (`sops: command not found` in the
  very next step).
- **v0.1.1** tried passing `${{ runner.temp }}`/`${{ github.workspace }}` as
  `args` — hit gap 1 (the consuming workflow failed before the action even
  ran).
- **v0.1.2** is the real fix: `action.yml` is a `using: composite` action.
  Its one `run:` step executes *natively* on the runner (not inside any
  container), where `$RUNNER_TEMP` is simply correct — no translation, no
  context restriction — and it explicitly `docker run -v
  "$RUNNER_TEMP/...":/out"` the pinned image itself, so the binaries land
  directly at a real, known runner-side path before `GITHUB_PATH` is ever
  touched. Still fully Docker-based: the actual pinned, checksum-verified
  binaries only ever exist inside the published container image;
  `action.yml` just orchestrates pulling them out from a context that can
  see both sides of the mount.

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
