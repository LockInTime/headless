# Tag-triggered Release CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pushing a `v*` tag builds, tests, and publishes macOS zip + Linux amd64/arm64 tarballs to a GitHub Release.

**Architecture:** One workflow (`.github/workflows/release.yml`) with three parallel package jobs and a publish job. Reuse existing `build.sh`, `build-linux.sh`, and test scripts. Only `build.sh` gains a `HEADLESS_VERSION` env hook for Info.plist.

**Tech Stack:** GitHub Actions, `softprops/action-gh-release`, existing shell build/test scripts, Docker on Ubuntu runners.

## Global Constraints

- Trigger: `v*` tags only
- Artifacts: `Headless-$VERSION-macos.zip`, `headless-$VERSION-linux-amd64.tar.gz`, `headless-$VERSION-linux-arm64.tar.gz`
- Tests must pass before Release creation
- No `.dmg`, notarization, GHCR, or distro packages
- Spec: `docs/superpowers/specs/2026-07-19-release-ci-design.md`

---

### Task 1: Versioned macOS Info.plist in `build.sh`

**Files:**
- Modify: `apps/headless/build.sh` (Info.plist generation around lines 66–89)

**Interfaces:**
- Consumes: `HEADLESS_VERSION` env (optional; default `1.0.0`)
- Produces: `CFBundleShortVersionString` = version; `CFBundleVersion` = same version string

- [ ] **Step 1: Change plist heredoc to use `HEADLESS_VERSION`**

Near the top of `build.sh` (after `cd`), add:

```zsh
VERSION="${HEADLESS_VERSION:-1.0.0}"
```

Replace the quoted heredoc `<<'PLIST'` with an unquoted `<<PLIST` (or `<<EOF`) and substitute:

```xml
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
```

Keep all other plist keys unchanged. Escape nothing else — `$VERSION` is the only expansion.

- [ ] **Step 2: Smoke-check version injection locally if on macOS**

```sh
HEADLESS_VERSION=9.9.9 ./apps/headless/build.sh
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' apps/headless/Headless.app/Contents/Info.plist
```

Expected: `9.9.9`

On Linux CI hosts this step is N/A; verify via reading the script that `${VERSION}` appears in the plist template.

- [ ] **Step 3: Commit**

```bash
git add apps/headless/build.sh
git commit -m "build: accept HEADLESS_VERSION for macOS Info.plist"
```

---

### Task 2: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `github.ref_name` tag; Task 1 `HEADLESS_VERSION`
- Produces: GitHub Release with three assets

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      - id: version
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

  macos:
    needs: version
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        env:
          HEADLESS_VERSION: ${{ needs.version.outputs.version }}
        run: ./apps/headless/build.sh
      - name: Unit tests
        run: ./apps/headless/test.sh
      - name: E2E
        run: ./apps/headless/Tests/macos-e2e.sh
      - name: Package
        env:
          VERSION: ${{ needs.version.outputs.version }}
        run: |
          cd apps/headless
          ditto -c -k --keepParent Headless.app "Headless-${VERSION}-macos.zip"
      - uses: actions/upload-artifact@v4
        with:
          name: macos
          path: apps/headless/Headless-${{ needs.version.outputs.version }}-macos.zip

  linux-amd64:
    needs: version
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: HEADLESS_LINUX_PLATFORM=linux/amd64 ./apps/headless/build-linux.sh
      - name: E2E
        run: ./apps/headless/Tests/linux-docker.sh
      - name: Package
        env:
          VERSION: ${{ needs.version.outputs.version }}
        run: |
          cp apps/headless/build/headless-linux-amd64.tar.gz \
            "apps/headless/build/headless-${VERSION}-linux-amd64.tar.gz"
      - uses: actions/upload-artifact@v4
        with:
          name: linux-amd64
          path: apps/headless/build/headless-${{ needs.version.outputs.version }}-linux-amd64.tar.gz

  linux-arm64:
    needs: version
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: HEADLESS_LINUX_PLATFORM=linux/arm64 ./apps/headless/build-linux.sh
      - name: E2E
        run: ./apps/headless/Tests/linux-docker.sh
      - name: Package
        env:
          VERSION: ${{ needs.version.outputs.version }}
        run: |
          cp apps/headless/build/headless-linux-arm64.tar.gz \
            "apps/headless/build/headless-${VERSION}-linux-arm64.tar.gz"
      - uses: actions/upload-artifact@v4
        with:
          name: linux-arm64
          path: apps/headless/build/headless-${{ needs.version.outputs.version }}-linux-arm64.tar.gz

  publish:
    needs: [version, macos, linux-amd64, linux-arm64]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: dist
          merge-multiple: true
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: Headless ${{ needs.version.outputs.version }}
          body: |
            ## Downloads

            | File | Platform |
            | --- | --- |
            | `Headless-${{ needs.version.outputs.version }}-macos.zip` | macOS (ad-hoc signed `.app`) |
            | `headless-${{ needs.version.outputs.version }}-linux-amd64.tar.gz` | Linux x86_64 |
            | `headless-${{ needs.version.outputs.version }}-linux-arm64.tar.gz` | Linux arm64 |

            ### Notes

            - **macOS:** Unzip and run `Headless.app`. Gatekeeper may warn (ad-hoc signature; notarization not included yet). CLI: `Headless.app/Contents/Resources/bin/headless`.
            - **Linux tarball:** Does not bundle Chromium. Install with `./install-linux.sh` after ensuring non-Snap Chromium and FFmpeg are available. The Docker production image remains the self-contained runtime (not published by this release).
          files: |
            dist/Headless-${{ needs.version.outputs.version }}-macos.zip
            dist/headless-${{ needs.version.outputs.version }}-linux-amd64.tar.gz
            dist/headless-${{ needs.version.outputs.version }}-linux-arm64.tar.gz
          fail_on_unmatched_files: true
```

Note: `build-linux.sh` sets `PLATFORM_LABEL` from `HEADLESS_LINUX_PLATFORM` after `##*/`, so `linux/amd64` → `amd64` and `linux/arm64` → `arm64`. That matches the `cp` source names above.

- [ ] **Step 2: YAML sanity check**

```sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"
```

Expected: no error (if PyYAML missing, `pip install pyyaml` or skip and visually verify).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add tag-triggered release workflow"
```

---

### Task 3: README release note

**Files:**
- Modify: `README.md` (after Build section or at end of Build)

- [ ] **Step 1: Add a short Releases subsection**

After the Linux build instructions (before `## Tests`), add:

```markdown
### GitHub Releases

Pushing a version tag publishes downloadable packages:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Assets: macOS `Headless.app` zip, Linux amd64/arm64 tarballs. See the Actions
`Release` workflow and the release notes on each tag for install caveats
(Gatekeeper; Linux Chromium/FFmpeg).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: note tag-triggered GitHub Releases"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| `v*` trigger + version from tag | Task 2 |
| macOS build/test/zip | Task 2 `macos` job |
| Linux amd64/arm64 tarballs + E2E | Task 2 linux jobs |
| Publish only after all succeed | Task 2 `publish` needs |
| `HEADLESS_VERSION` in Info.plist | Task 1 |
| Release notes caveats | Task 2 body + Task 3 |
| Out of scope items omitted | verified — no dmg/GHCR/deb |
