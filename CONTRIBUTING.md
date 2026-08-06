# Contributing to Headless

Thanks for working on this. Headless is a security-boundary product: agents
drive real browsers through it, and the host — not the prompt — is what stops
them doing something harmful. That shapes how we review changes, so please
read this before your first PR.

Contributors are humans *and* coding agents. If you are an agent, your rules
live in [`AGENTS.md`](AGENTS.md); everything below applies to you too.

## Before you start

1. **Find or open an issue.** Every known defect and gap is already filed —
   see the [backlog](docs/roadmap/improvements-backlog.md) and the matching
   GitHub issues, labelled `backlog` and grouped into milestones by roadmap
   phase. Good entry points carry `good first issue`.
2. **Read the contracts.** [`docs/roadmap/what-is-excellent.md`](docs/roadmap/what-is-excellent.md)
   lists twelve properties that define the product. A PR that weakens one is
   rejected on principle, not on style — even if the code is good.
3. **Check the decisions.** [`docs/roadmap/architecture-decisions.md`](docs/roadmap/architecture-decisions.md)
   records what is already settled (the core stays Swift; no hosted service;
   Windows is a stretch goal). If your change contradicts one, propose a new
   decision entry in the same PR rather than quietly diverging.

Anything that changes the agent-facing contract — a new verb, a new
parameter, a changed response shape, a relaxed safety rule — needs an
architecture-decision entry **before** the implementation lands.

## Development setup

```sh
pnpm install                 # workspace tooling (Node 22+, pnpm 9)
pnpm test                    # protocol/security suite — needs a Swift toolchain
pnpm test:runtime            # jsdom context-pruning suite — Node only
pnpm test:e2e:linux          # Docker + sandboxed Chromium E2E
pnpm test:e2e:mac            # real WKWebView E2E (macOS GUI session)
```

Platform notes:

- **macOS** builds need Xcode Command Line Tools; `pnpm build` produces
  `Headless.app`. FFmpeg is required for recording and visual diffs.
- **Linux** builds need only Docker: `pnpm build:linux` compiles inside
  `swift:6.1-bookworm` and emits a tarball. Chromium must be non-Snap —
  the runtime rejects Snap launchers before starting, by design.
- **Rootless Docker works**, including the E2E: Chromium's nested namespace
  sandbox runs fine, and the harness detects the daemon mode so exported QA
  evidence comes back owned by you. Nothing binds a host port, so the suites
  cannot collide with other services on a shared machine.
- `pnpm test:e2e:mac` opens real windows and mutates `com.headless.app` user
  defaults. Don't run it in a background session or on a machine where that
  matters.

## The bar for a pull request

- `pnpm test` and `pnpm test:runtime` pass locally.
- Run `pnpm test:e2e:linux` if you touched a host, the transport, the agent
  runtime JS, or artifact code. Add the `macos-e2e` label to the PR if you
  touched `main.swift`, `Host/`, or capture code — that triggers the heavier
  WKWebView suite in CI.
- New behaviour ships with a test. New *safety* behaviour ships with a test
  that fails without the fix.
- A protocol command still has to be added in both hosts, the validator, the
  CLI, the help text, and `capabilities` until the HostCore refactor
  ([#21](https://github.com/LockInTime/headless/issues/21)) lands. Keep the
  copies in sync.
- If you fixed a backlog item, check it off in
  `docs/roadmap/improvements-backlog.md` in the same PR and close the issue.

CI runs on every PR: static checks, the agent-runtime suite, the protocol
suite on Linux and macOS, the web lint/build, and the Linux Docker E2E. All of
it uses the same scripts you ran locally, so a green laptop should mean a
green PR.

## Style

- **Swift:** Foundation and system frameworks only. No new SwiftPM
  dependencies without an architecture-decision entry — the zero-dependency
  supply chain is a feature. Explicit validation, small structs, and no
  force-unwraps in host paths (the existing ones are tracked defects, not
  precedent).
- **Shell:** POSIX `sh` unless you need bash; scripts are syntax-checked in
  CI.
- **Web:** the site currently duplicates content by hand in three places.
  If you change CLI behaviour, grep `apps/web` and `README.md` and update
  every copy until [#48](https://github.com/LockInTime/headless/issues/48)
  makes that unnecessary.
- **Commits:** conventional-ish prefixes — `feat:`, `fix:`, `docs:`, `ci:`,
  `refactor:`, `test:`, `chore:`, with an optional scope such as
  `fix(macos):`.

## Media and evidence

Never commit images or video except regenerated QA evidence under
`docs/qa/evidence/`, which is checksum-verified in CI. Local artifacts belong
in `build/qa-evidence/` (gitignored). If your change alters what a recording
or screenshot looks like, regenerate the affected evidence and update
`SHA256SUMS`.

## Reporting security issues

Do not open a public issue. See [`SECURITY.md`](SECURITY.md).

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
