# Design: Tag-triggered release CI

## Goal

Add a GitHub Actions release pipeline so pushing a `v*` tag builds, tests, and
publishes downloadable macOS and Linux packages to a GitHub Release.

## Decisions (locked)

| Choice | Value |
| --- | --- |
| Trigger | Tag-only (`v*`), e.g. `v1.0.0` |
| Scope | Minimum viable artifacts (no `.dmg`, notarization, GHCR, or distro packages) |
| Quality gate | Tests must pass before the Release is created |
| Workflow shape | Single workflow file |

## Trigger & versioning

- Workflow path: `.github/workflows/release.yml`
- Trigger: `on.push.tags: ["v*"]`
- Version = tag with leading `v` stripped (`v1.2.3` → `1.2.3`)
- GitHub Release title/name uses that version
- Artifact filenames include the version

## Jobs

All package jobs run in parallel. A final publish job runs only if every
package job succeeds.

### 1. macOS (`macos-latest`)

1. Checkout
2. `./apps/headless/build.sh` with `HEADLESS_VERSION` set from the tag
3. `./apps/headless/test.sh` (protocol unit tests)
4. `./apps/headless/Tests/macos-e2e.sh`
5. Zip `Headless.app` → `Headless-$VERSION-macos.zip`
6. Upload workflow artifact

Codesign stays ad-hoc (existing `build.sh` default). No notarization in v1.

### 2. Linux amd64 (`ubuntu-latest`)

1. Checkout
2. `HEADLESS_LINUX_PLATFORM=linux/amd64 ./apps/headless/build-linux.sh`
3. `./apps/headless/Tests/linux-docker.sh`
4. Rename/copy tarball → `headless-$VERSION-linux-amd64.tar.gz`
5. Upload workflow artifact

Docker is required on the runner (already present on GitHub-hosted Ubuntu).

### 3. Linux arm64 (`ubuntu-24.04-arm`)

Native arm64 runner. Same steps as amd64 with
`HEADLESS_LINUX_PLATFORM=linux/arm64`, producing
`headless-$VERSION-linux-arm64.tar.gz`.

E2E runs on this runner via `./apps/headless/Tests/linux-docker.sh`, so the
tested path matches the published architecture.

If GitHub arm runners are unavailable in the org, fall back to `ubuntu-latest`
+ `HEADLESS_LINUX_PLATFORM=linux/arm64` (QEMU). In that fallback, still run
`linux-docker.sh` on amd64 (validates the Linux Docker path; the arm64 tarball
comes from the cross platform build).

### 4. Publish

1. Download the three package artifacts
2. Create a GitHub Release for the pushed tag
3. Attach:
   - `Headless-$VERSION-macos.zip`
   - `headless-$VERSION-linux-amd64.tar.gz`
   - `headless-$VERSION-linux-arm64.tar.gz`
4. Permissions: `contents: write` only on this job

If any earlier job fails, no Release is created.

## Artifacts (what users download)

| File | Contents |
| --- | --- |
| `Headless-$VERSION-macos.zip` | `Headless.app` (CLI under `Contents/Resources/bin/`) |
| `headless-$VERSION-linux-amd64.tar.gz` | `headless`, `headless-host`, `headless-mcp`, `install-linux.sh`, docs |
| `headless-$VERSION-linux-arm64.tar.gz` | Same layout for arm64 |

Linux tarballs do **not** bundle Chromium. Release notes should state:

- Native Linux installs need non-Snap Chromium + FFmpeg (`install-linux.sh` checks)
- Docker `production` image remains the self-contained Linux runtime (not published by this pipeline)

macOS zip is ad-hoc signed; Gatekeeper may warn until Developer ID + notarization
are added later.

## Code changes outside the workflow

### `apps/headless/build.sh`

- Accept `HEADLESS_VERSION` (default `1.0.0` for local builds)
- Write `CFBundleShortVersionString` (and a sensible `CFBundleVersion`) from that value instead of hardcoding `1.0.0` / `1`

No other packaging format changes. Reuse `build-linux.sh` and existing test
scripts as-is; only rename outputs in the workflow for stable Release names.

## Failure behavior

- Failed unit/e2e or build → job fails → publish skipped
- Do not use `continue-on-error` on package/test steps
- Do not create draft releases on failure

## Out of scope (v1)

- `.dmg`, Developer ID signing, notarization, stapling
- Publishing Docker images to GHCR / Docker Hub
- `.deb`, `.rpm`, AppImage, Homebrew cask/formula
- PR or `main` branch CI (can be a follow-up that reuses the same scripts)
- Windows builds
- Auto-versioning / release-please / changelog generation from commits

## Follow-ups (documented, not this work)

1. Notarized macOS `.dmg` with Developer ID secrets in GitHub
2. Push `Dockerfile.linux` `production` to GHCR on the same tag
3. Optional PR CI workflow calling the same test scripts

## Success criteria

1. `git tag vX.Y.Z && git push origin vX.Y.Z` starts the workflow
2. All three package jobs build and test successfully
3. A GitHub Release appears on that tag with exactly the three files above
4. Local `./apps/headless/build.sh` still works without setting `HEADLESS_VERSION`
