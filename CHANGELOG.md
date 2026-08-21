# Changelog

All notable changes to Headless are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are tagged `vX.Y.Z` and published by
[`.github/workflows/release.yml`](.github/workflows/release.yml).

Two versions travel independently, on purpose:

- **Product version**: the git tag, embedded in every binary via
  `HEADLESS_VERSION`, reported by the CLI, host, and MCP adapter, and used for
  release assets.
- **Protocol version**: `headlessProtocolVersion` in `Protocol.swift`,
  currently `0.5`. It changes only when the wire contract changes, and always
  with an entry in
  [`docs/roadmap/architecture-decisions.md`](docs/roadmap/architecture-decisions.md).

## [Unreleased]

No changes yet.

## [1.1.0] — 2026-08-21

This release carries the roadmap work completed since v1.0.2, including
progressive context pruning, expanded capture formats, a shared cross-engine
core and conformance suite, trusted Chromium input, hardened distribution, and
deeper agent-harness integration.

### Added

- Chromium `click`, `fill`, and `press` now dispatch trusted mouse, keyboard,
  and text input through CDP after isolated-world semantic target and link
  safety validation; capabilities declare the WebKit synthetic-input boundary.
- Tagged macOS releases now ship a universal Apple Silicon/Intel app through a
  checksum-pinned Homebrew cask, with Developer ID signing, hardened runtime,
  notarization, stapling, and Gatekeeper validation enforced by release CI.
- A checksum-verifying `@lockintime/headless` npm launcher now provides the
  CLI and MCP adapter to JavaScript-centric agent harnesses through `npx`.
- Tagged releases now publish a smoke-tested, non-root amd64/arm64 production
  image to GHCR with SemVer and commit-SHA tags, provenance, and an SBOM.
- A checksum-verifying Linux bootstrap installer now selects the correct
  amd64/arm64 release package and delegates to the shared runtime preflight.
- Tagged releases now include a verified `SHA256SUMS` manifest covering every
  downloadable macOS and Linux package.
- A single cross-engine conformance scenario now runs against real WKWebView
  and Chromium hosts, locking shared response shapes and declared capability
  errors without mirrored platform assertions.
- A generated WebKit/Chromium capability matrix now declares exhaustive
  command support and intentional engine differences; host ping responses
  include the active engine profile.
- The comparison benchmark now emits a validated JSON results artifact with
  raw samples and medians, and its refreshed Headless workflows include
  task-aware action inspection.
- The single MCP tool now accurately declares its mutating, destructive,
  non-idempotent, open-world behavior; integration tests lock the metadata and
  deliberate `stop` / `session close` exposure.
- An MCP stdio integration suite covering initialization, tool discovery,
  browser-command calls, malformed and oversized input, and rejection of local
  CLI commands.
- CLI parser coverage for the previously untested session, navigation,
  diagnostics, flow, network emulation, reporting, and local command paths.
- Core regression coverage for bounded artifact reads, non-regular artifacts,
  non-replayable fill values in flows, and the ffmpeg visual-difference path.
- Agent-runtime regression coverage for interaction commands, page state,
  tours, screenshot-plan bounds and deduplication, budget fallback, unsafe
  links, and stale element references.
- Recording and transport regression coverage for every ffmpeg format/quality
  mapping, executable discovery, capture-failure and stop bounds, capabilities
  accuracy, and oversized Unix-socket requests.
- Cross-uid Unix-socket rejection and host E2E classification checks for
  blocked top-frame navigation and denied page-initiated downloads.
- macOS explicitly converts download-intent links, attachment responses, and
  unsupported response types into cancellable `WKDownload` objects so every
  denied download is classified without writing page-controlled bytes.
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

- Machine-readable capabilities now derive their command and engine inventories
  exhaustively from the protocol enums, preventing new commands or engines from
  being silently omitted.
- Web dependencies refreshed (Next.js group, lucide-react, TypeScript 6 bridge,
  @types/node).

- macOS agent startup now opens browser windows without activating Headless or
  covering the user's current app. The startup presentation can be configured
  persistently or overridden for one launch.
- Product versions now come from the release tag at build time and are
  reported consistently by `headless --version`, host `ping`, MCP
  `serverInfo`, package metadata, and the website. Release notes are generated
  automatically for each tag while protocol versioning stays independent.
- The release workflow can now exercise and verify every package without
  publishing, manually or on pull requests that change packaging inputs.
- macOS WebKit and Linux Chromium now share one `HostCore` dispatcher and
  lifecycle implementation behind small engine adapters, eliminating the two
  divergent copies of flow, capture, recording, report, trace, and error logic.
- Protocol 0.5 marks diagnostic reports, events, derived issues, console
  messages, and network evidence as untrusted page content. The macOS
  page-world observer now has host-owned provenance and a per-document cap.
- Both engines now install the compiled agent-runtime resource once per
  document; Chromium caches and safely invalidates its isolated context instead
  of resending the runtime for every command.
- Context-budget pruning now measures each candidate once, removes oversized
  entries regardless of array position, and byte-budgets text fallback.
- Removed stale screenshot and JSON conversion paths, honored per-operation
  Linux evaluation timeouts, and stopped advertising the compatibility-only
  `--json` flag.
- QA evidence now includes a recorded progressive-pruning scenario, and the
  committed bundle is checksum-verified in CI.
- Repository moved to the `LockInTime` organisation; site links updated.
- The website now runs on Next.js 16 with its native flat ESLint configuration;
  the legacy `FlatCompat` and `@eslint/eslintrc` path has been removed.

### Fixed

- The macOS app no longer disables App Transport Security process-wide. Its
  HTTP compatibility exception is limited to browser web content.
- WebKit and Chromium now agree on empty-history `back` failures and enforce
  the same bounded key input before dispatch.
- Portable name characters, local-development hosts, scroll bounds, and
  network-emulation bounds now have one definition shared by CLI validation,
  protocol validation, and diagnostics; tests also lock the Swift/JavaScript
  unsafe-resource extension sets together.
- Browser-operation failures now cross both WebKit and CDP as structured,
  allowlisted error codes instead of host-side matching on error-message text.
- Linux DevTools-pipe framing now tracks its scan cursor and amortizes buffer
  compaction, avoiding quadratic work for large screenshot responses.
- Phase 1 hardening now bounds Chromium teardown after `SIGKILL`, uses libc's
  peer-credential constant, deterministically caps diagnostic headers, drops
  malformed CDP header values, atomically finalizes artifacts without
  overwriting, and derives the long transport timeout for flow replay.
- Recording startup replaces its three-second busy poll with six short,
  bounded backoff attempts, and status no longer reads `Process.isRunning`
  across threads.
- macOS now keeps manual and agent-controlled browsing inside the same HTTP(S)
  navigation boundary instead of dispatching application or script schemes.
- Unknown `qa` subcommands now report the command error before inspecting
  irrelevant trailing options.
- `fill` preserves quoted whitespace and accepts literal `--json` or
  `--session` values after the standard `--` end-of-options sentinel.

### Known gaps

Tracked as [`backlog`](https://github.com/LockInTime/headless/labels/backlog)
issues, grouped by roadmap phase into milestones. Highlights include deferred
interaction design ([#35](https://github.com/LockInTime/headless/issues/35)),
website and documentation depth
([#47](https://github.com/LockInTime/headless/issues/47)–[#53](https://github.com/LockInTime/headless/issues/53)),
and stretch Windows support
([#56](https://github.com/LockInTime/headless/issues/56)).

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

[Unreleased]: https://github.com/LockInTime/headless/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/LockInTime/headless/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/LockInTime/headless/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/LockInTime/headless/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/LockInTime/headless/releases/tag/v1.0.0
