# Changelog

All notable changes to Headless are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are tagged `vX.Y.Z` and published by
[`.github/workflows/release.yml`](.github/workflows/release.yml).

Two versions travel independently, on purpose:

- **Product version** — the git tag, flowing into the macOS `Info.plist` via
  `HEADLESS_VERSION` and into release assets.
- **Protocol version** — `headlessProtocolVersion` in `Protocol.swift`,
  currently `0.4`. It changes only when the wire contract changes, and always
  with an entry in
  [`docs/roadmap/architecture-decisions.md`](docs/roadmap/architecture-decisions.md).

## [Unreleased]

Everything below has landed on `main` but is **not yet in a tagged release**.
Cutting that release is tracked in
[#45](https://github.com/LockInTime/headless/issues/45).

### Added

- Progressive context pruning: `inspect --context summary|outline|text|actions|full`
  with `--task` ranking, `--within @rN` scoping, and `--limit` / `--budget` /
  `--depth` bounds. Every focused response reports `contextStats` and `omitted`.
  Measured 94.5 % estimated-token reduction on the 120-section fixture.
- Capture formats: JPG/JPEG and PDF screenshots, `--every-viewport` and
  `--by-section` screenshot series, and MOV/WebM/GIF recording containers.
- Product documentation set — [`docs/ROADMAP.md`](docs/ROADMAP.md),
  [what is excellent](docs/roadmap/what-is-excellent.md),
  [architecture decisions](docs/roadmap/architecture-decisions.md), and the
  [improvements backlog](docs/roadmap/improvements-backlog.md).
- Contributor rule files for every coding harness: [`AGENTS.md`](AGENTS.md)
  and `CLAUDE.md`.
- Continuous integration on every pull request
  ([`ci.yml`](.github/workflows/ci.yml)): static checks, agent-runtime suite,
  protocol suite on Linux and macOS, web lint and build, and the Linux Docker
  E2E. The macOS WKWebView E2E runs nightly or on the `macos-e2e` label.
- Repository governance: MIT `LICENSE` preserving the upstream chromeless
  notice, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue forms,
  a pull-request template, `CODEOWNERS`, and Dependabot.

### Changed

- QA evidence now includes a recorded progressive-pruning scenario, and the
  committed bundle is checksum-verified in CI.
- Repository moved to the `LockInTime` organisation; site links updated.
- The website now runs on Next.js 16 with its native flat ESLint configuration;
  the legacy `FlatCompat` and `@eslint/eslintrc` path has been removed.

### Known gaps

Tracked as [`backlog`](https://github.com/LockInTime/headless/labels/backlog)
issues, grouped by roadmap phase into milestones. Highlights:
a shutdown data race on the Linux host
([#12](https://github.com/LockInTime/headless/issues/12)), responses that can
exceed the 1 MiB frame ([#14](https://github.com/LockInTime/headless/issues/14)),
and unsigned macOS builds
([#39](https://github.com/LockInTime/headless/issues/39)).

## [1.0.2] — 2026-07-19

### Fixed

- macOS: recover when a restored page is unavailable at launch.

## [1.0.1] — 2026-07-19

### Fixed

- Release CI: harden the macOS E2E suite for GitHub runners.

## [1.0.0] — 2026-07-19

First tagged release: the P0–P2 contract on macOS and Linux.

### Added

- Persistent host with a versioned JSON protocol over a private per-user Unix
  socket, peer-UID checked, with no TCP listener and no arbitrary-JavaScript
  verb.
- Two engines behind one CLI contract: macOS WKWebView windows, Linux
  sandboxed Chromium driven over the inherited DevTools fd-3/4 pipe.
- Semantic interaction — `visit`, `inspect`, `click`, `fill`, `press`,
  `scroll`, `wait`, `tour`, `back`, `reload` — targeted by role/name or by
  element reference.
- Evidence capture: screenshots, built-in FFmpeg recording, visual comparison,
  flows, and QA reports, written to a `0700` per-user artifact store with
  `0600` non-overwriting files.
- Diagnostics with redaction: console, network, cookies, storage, computed
  styles, performance, and animations. Sensitive values are double-gated.
- Linux-only network emulation and request mocking; macOS returns
  `UNSUPPORTED_CAPABILITY` rather than partially emulating.
- `headless-mcp`, a stdio MCP server exposing the CLI as a single `argv` tool.
- Snap Chromium rejection before launch, after it proved unreliable over the
  DevTools pipe.
- Tag-triggered release workflow publishing a macOS app zip and Linux
  amd64/arm64 tarballs.

[Unreleased]: https://github.com/LockInTime/headless/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/LockInTime/headless/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/LockInTime/headless/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/LockInTime/headless/releases/tag/v1.0.0
