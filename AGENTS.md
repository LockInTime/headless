# AGENTS.md — working on the Headless repo

Guidance for any coding agent (and any human) contributing to this repository.
Claude Code reads this via `CLAUDE.md`; Codex/OpenCode/Cursor/Amp read it
directly.

## What this project is

Headless gives AI agents a persistent, safety-enforced browser driven by a
semantic CLI (`headless click --role button --name Continue`) instead of
Playwright scripts or screen coordinates. Two engines behind one contract:
macOS WKWebView app, Linux sandboxed Chromium over the DevTools fd-3/4 pipe.
Control plane is a private per-user Unix socket; there is deliberately **no
TCP listener and no arbitrary-JavaScript verb**.

Read before making non-trivial changes:

- `docs/ROADMAP.md` — product plan, phases, definition of done.
- `docs/roadmap/what-is-excellent.md` — contracts you must not weaken.
- `docs/roadmap/architecture-decisions.md` — settled decisions (e.g. the core
  stays Swift; don't propose rewrites).
- `docs/roadmap/improvements-backlog.md` — known defects with file/line refs;
  check items off when you fix them and add the named test.
- `CONTRIBUTING.md` — the same rules for humans, plus setup detail.
- `SECURITY.md` — the boundaries a bug report is measured against.
- To *use* Headless as a browser tool (rather than develop it), follow the
  skill: `.agents/skills/headless-computer-use/SKILL.md`.

## Layout

- `apps/headless/` — the product; one SwiftPM package, zero third-party Swift
  deps (keep it that way).
  - `Sources/HeadlessProtocol/` — shared core: protocol, CLI parser, agent
    runtime JS (embedded string in `AgentRuntime.swift`), artifacts,
    recording, diagnostics.
  - `main.swift` + `Host/` — macOS WKWebView host (Cocoa; macOS-only).
  - `LinuxHost/` — Linux Chromium host (fork/exec + CDP over fd 3/4).
  - `MCP/main.swift` — stdio MCP server exposing the CLI as one `argv` tool.
  - `Tests/` — protocol suite, jsdom runtime suite, E2E shell suites,
    benchmark harness, fixtures.
- `apps/web/` — Next.js marketing/docs site.
- `docs/` — roadmap set, QA evidence (`docs/qa/evidence/` — the only binary
  media allowed in git), phase contracts in `apps/headless/docs/P0|P1|P2.md`.

## Build & test

```sh
pnpm test              # protocol/security suite (builds Swift; needs swiftc on macOS)
pnpm test:runtime      # jsdom context-pruning suite (node only)
pnpm test:e2e:linux    # Docker + sandboxed Chromium E2E (needs Docker)
pnpm test:e2e:mac      # real WKWebView E2E (macOS GUI session; mutates user defaults)
pnpm build             # macOS app + web
pnpm build:linux       # Linux binaries via Docker (no local Swift needed)
```

Minimum bar for a PR touching `apps/headless`: `pnpm test` and
`pnpm test:runtime` pass; run the Linux E2E if you changed host, transport,
runtime JS, or artifact code.

`.github/workflows/ci.yml` gates every PR with the same scripts: static checks
(shell syntax, QA evidence checksums), the agent-runtime suite, the protocol
suite on Linux (Swift container) and macOS, the web lint/build, and the Linux
Docker E2E. The macOS WKWebView E2E is heavier — it runs nightly, on
`workflow_dispatch`, or when a PR carries the `macos-e2e` label. Run it that
way before merging changes to `main.swift`, `Host/`, or capture code.

## Picking up work

Every open backlog item is a GitHub issue labelled `backlog`, cross-linked
from the backlog file in both directions, carrying type/area/priority labels,
sitting in the milestone for its roadmap phase, and tracked on the
[Headless Roadmap board](https://github.com/orgs/LockInTime/projects/1). Work from either surface —
but when you fix something, close the issue **and** check the item off in
`docs/roadmap/improvements-backlog.md` in the same PR, so the two never drift.

Phase 1 (`Trust the build`) is the current milestone; `priority:critical` and
`priority:high` items there come first. `good first issue` marks the
self-contained ones.

Anything that changes the agent-facing contract needs an entry in
`docs/roadmap/architecture-decisions.md` before the code lands.

## Hard rules (host-enforced contracts — never weaken)

1. No arbitrary-JS execution verb; no TCP listener; no Chromium debug port.
2. HTTP/HTTPS navigation only; downloads denied; dangerous extensions
   blocked. All page-derived text stays marked `untrustedContent`.
3. Artifacts: validated bare names, `O_EXCL` create `0600` in the `0700`
   per-user store, never overwrite, never path-traverse.
4. Fail closed: unknown params rejected; Snap Chromium rejected; root
   refused; missing capability → `UNSUPPORTED_CAPABILITY`, never silent
   partial behavior.
5. Flows never record `fill` values. Cookie/storage values stay double-gated
   (`--values` + `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`).
6. Every bounded thing stays bounded and reports truncation (`omitted`,
   `truncated`, `contextStats`).

If a change brushes against any of these, stop and record a decision in
`docs/roadmap/architecture-decisions.md` first.

## Conventions

- Swift: Foundation + system frameworks only; no new SwiftPM dependencies
  without an architecture-decision entry. Match existing style (explicit
  validation, small structs, no force-unwraps in host paths — existing ones
  are backlog items §A2, don't add more).
- A new protocol command currently must be added in *both* hosts
  (`main.swift` and `LinuxHost/main.swift`), the validator
  (`Protocol.swift`), the CLI (`CLI.swift`), help text, and `capabilities` —
  until the Phase 2 HostCore refactor lands, keep all copies in sync and add
  parse + E2E coverage on both platforms.
- The agent runtime JS lives in `Sources/HeadlessProtocol/AgentRuntime.swift`
  as a raw string; `Tests/agent-runtime.test.mjs` regex-extracts it — if you
  touch the string delimiters, fix the extractor.
- Media policy: never commit images/videos except regenerated evidence under
  `docs/qa/evidence/`; local artifacts go to `build/qa-evidence/` (gitignored).
  Brand images are generated from code, never committed — see `docs/brand.md`.
- Docs: feature docs live in the phase contracts (P0/P1/P2 style — contract,
  deferrals, known limitations). Keep README claims backed by tests or
  evidence.
- Web (`apps/web`): content is currently hand-duplicated in three places
  (backlog §F2) — if you change CLI behavior, grep the site
  (`app/docs/page.tsx`, `components/docs-markdown.ts`, `README.md`) and
  update all copies.
- Commits: conventional-ish prefixes in use (`feat:`, `fix:`, `docs:`,
  `ci:`, scope in parens like `fix(macos):`).

## Versioning & release

Tags `v*` trigger `.github/workflows/release.yml` (macOS zip + Linux
tarballs). `HEADLESS_VERSION` flows from the tag; protocol version (`"0.5"`
in `Protocol.swift`) is independent — bump it only for wire-visible changes,
with a decision entry.
