# Headless — Product Roadmap

**Status:** living document. This is the main reference for everyone working on
Headless over the coming months. Read this first; it links to three companion
documents that carry the detail:

1. [What is excellent — do not change](roadmap/what-is-excellent.md)
   The ideas and implementations that define the product. Changing these
   requires a written proposal, not a refactor PR.
2. [Architecture decisions](roadmap/architecture-decisions.md)
   Whether we keep Swift, how the two-host model evolves, transport, errors,
   the Windows plan, and every other keep/change decision with reasons.
3. [Improvements backlog](roadmap/improvements-backlog.md)
   The full information dump: every known defect, gap, and missing feature,
   with file/line references, grouped and prioritized.

Agent-facing rules live in [`AGENTS.md`](../AGENTS.md) (root) and the skill at
[`.agents/skills/headless-computer-use/`](../.agents/skills/headless-computer-use/SKILL.md).

---

## 1. The idea

**Headless gives AI agents a real, persistent browser they can drive with
semantic commands instead of screenshots-and-coordinates or Playwright
scripts.**

The three existing ways agents use browsers all have a structural flaw:

- **Coordinate computer-use**: the agent looks at screenshots and clicks
  pixels. Imprecise, token-hungry, and the blast radius is the whole desktop.
- **Scripted automation (Playwright / Puppeteer / Selenium)**: reliable, but
  the agent has to write and maintain driver code, and safety/evidence are
  bolted on afterwards.
- **Raw CDP / devtools**: powerful and completely unguarded.

Headless is the fourth way: a small CLI (`headless visit`, `headless click
--role button --name Continue`, `headless inspect --context actions --task
"finish onboarding"`) that talks to a persistent local browser host over a
private Unix socket. The host enforces the safety rules so the agent cannot
break them even when a hostile page tries to trick it. Every observation is
sized for an LLM context window, and every action leaves evidence (screenshots,
recordings, structured QA reports) an engineer can audit.

The product bet, in one sentence: **agents are a new kind of browser user, and
they deserve a browser interface designed for them** — token-frugal output,
stable semantic references, deny-by-default safety, and built-in proof of what
happened.

### Who it is for

- **Coding agents** (Claude Code, Codex, OpenCode, Cursor, any MCP client)
  verifying the web apps they just built: visit the dev server, click through
  the flow, record a video, attach the evidence to the PR.
- **QA automation driven by agents**: reproducible flows, visual diffs,
  console/network diagnostics, network mocking — without a test framework.
- **The engineers supervising those agents**, who need to trust that the agent
  could not download malware, exfiltrate cookies, or wander onto arbitrary
  sites, and who want artifacts they can verify independently.

### What it is not (non-goals)

These are deliberate, documented boundaries — see
[what-is-excellent](roadmap/what-is-excellent.md) before trying to "fix" any
of them:

- Not a desktop-automation tool. Browser only; no OS chrome, no native apps.
- Not a general scripting runtime. There is **no arbitrary JavaScript
  execution verb** and there never will be one on the default surface.
- Not a download manager. Page downloads are denied; only explicit Headless
  artifacts are ever written, into a private artifact store.
- Not a remote service (yet). No TCP listener, no debugger port. Remote use is
  `ssh host headless-mcp`. A hosted option is out of scope for this roadmap.
- Not a crawler/scraper platform. Sessions are for driving and verifying
  specific applications, primarily local/dev/staging web apps.

---

## 2. Where the project stands today (August 2026)

Honest snapshot, so newcomers know what is real:

**Working and verified**

- 39-verb JSON protocol over a `0600` Unix socket with peer-UID checks
  (`apps/headless/Sources/HeadlessProtocol/`).
- Two engines behind one CLI: macOS `WKWebView` app, Linux sandboxed Chromium
  over the DevTools fd-3/4 pipe (no debug port).
- Progressive context pruning (`inspect --context
summary|outline|text|actions|full`, `--task`, `--within @rN`, `--budget`)
  with a measured **94.5 % token reduction** on the 120-section fixture.
- Evidence capture: PNG/JPG/PDF screenshots, viewport/section series, MP4/MOV/
  WebM/GIF recordings, visual diffs, flows, QA reports.
- Diagnostics with redaction: console, network, cookies/storage (values
  gated), performance, animations.
- Linux-only network emulation and mocking.
- `headless-mcp`: a stdio MCP server exposing the whole CLI as one tool.
- A protocol test suite (~27 cases), a jsdom runtime suite, and macOS + Linux
  E2E scripts; 11 recorded QA evidence videos in `docs/qa/evidence/`.
- Tag-triggered release CI producing a macOS app zip and Linux
  amd64/arm64 tarballs (v1.0.0–v1.0.2 published).
- Phase 3 distribution automation for universal Developer ID macOS builds,
  notarization/stapling, a checksum-pinned Homebrew cask, the verified Linux
  bootstrap, release checksums, and a multi-platform GHCR image. These paths
  become user-visible with the next tag.
- A Next.js marketing/docs site (`apps/web`) — built, not deployed.
- An agent skill (`.agents/skills/headless-computer-use/`) with safety rules,
  command reference, and a Docker sandbox wrapper.

**Not yet real**

- ~~No CI on pull requests or `main`~~ — PR CI landed (`.github/workflows/ci.yml`,
  backlog §D1/§D3). Correctness fixes in §A are still outstanding, and the
  macOS E2E is nightly/label-gated rather than a per-PR gate.
- The verified npm launcher, Homebrew cask, notarized universal macOS ZIP,
  Linux bootstrap, release checksums, and GHCR publication paths are
  implemented but remain unreleased. Distro-native Linux packages remain
  unimplemented.
- The latest features (capture formats, context pruning) are **unreleased** —
  no tag since v1.0.2 (2026-07-19).
- No `CLAUDE.md`/`AGENTS.md`; the skill is not auto-discovered by Claude Code.
- The website's benchmark numbers, docs prose, and commands are hand-copied in
  three places each and will drift; the site has no deploy pipeline.
- Windows is not supported.
- A list of real code defects (thread-safety on shutdown, oversized `qa
report` responses, `@eN` ref invalidation surprises, host code duplication)
  — all catalogued in the [improvements backlog](roadmap/improvements-backlog.md).

---

## 3. Product principles

Every roadmap decision below follows from these. They are restated from the
codebase's existing behavior because they are the product:

1. **Fail closed.** Unknown parameter → reject. Snap Chromium → reject before
   launch. Root → refuse to run. Missing capability → `UNSUPPORTED_CAPABILITY`,
   never a silent partial emulation.
2. **The agent surface is a budget.** Every response is bounded, prunable, and
   reports what was omitted (`omitted`, `contextStats`, `truncated`). Token
   cost is a first-class metric with a benchmark.
3. **Page content is data, never instructions.** Everything derived from a page
   is marked `untrustedContent` and the host never executes it.
4. **Evidence over claims.** Features ship with recorded proof
   (`docs/qa/evidence/`), benchmarks state their limits, and docs never claim
   more than what is verified.
5. **Same contract on every platform.** One CLI, one protocol, one help text.
   Platform differences must be explicit capability errors, not silent
   behavioral drift.
6. **Local-first security.** Private socket, per-user isolation, no network
   listeners. Remote access rides on existing authenticated channels (SSH).

---

## 4. Platform support

| Platform                                     | Status today                                      | Target                                                                                                                                          |
| -------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **macOS 13+** (Apple Silicon)                | Universal signed release pipeline awaiting tag    | Signed + notarized, Homebrew, universal binary                                                                                                  |
| **macOS Intel**                              | Universal release pipeline awaiting tag           | Universal binary in release CI                                                                                                                  |
| **Linux** (Debian/Ubuntu, non-Snap Chromium) | Verified installer and GHCR pipeline awaiting tag | curl installer, published Docker image (GHCR), apt guidance                                                                                     |
| **Linux other distros**                      | Works where a non-Snap Chromium exists            | Documented candidate paths per distro family                                                                                                    |
| **Windows 10/11**                            | Not supported                                     | **Stretch goal (Phase W)** — Chromium host ported; not required for "done". See [architecture decisions §6](roadmap/architecture-decisions.md). |
| **Any OS via Docker**                        | Works (build locally)                             | `docker run ghcr.io/…/headless` one-liner, including as the practical Windows answer (WSL2/Docker Desktop) until Phase W lands                  |

Agent-harness support (the other axis of "platform"):

| Harness                                     | Today                         | Target                                                      |
| ------------------------------------------- | ----------------------------- | ----------------------------------------------------------- |
| MCP clients (Claude Code, Cursor, Codex, …) | `headless-mcp` stdio server   | unchanged core; per-client setup docs + `.mcp.json` example |
| Claude Code                                 | manual skill pointer          | root `CLAUDE.md` + discoverable skill                       |
| Codex / OpenCode / Amp / others             | `AGENTS.md` convention        | root `AGENTS.md` (done in this change)                      |
| Plain shell agents                          | CLI + `headless capabilities` | unchanged; capabilities doc kept machine-checked            |

---

## 5. Roadmap

Phases are ordered by dependency, not calendar. Each phase has an explicit
exit test. Work items reference the backlog
([improvements-backlog.md](roadmap/improvements-backlog.md)) by section, where
every item carries file/line detail.

### Phase 0 — Baseline honesty (this change)

Write down what the product is, what must not change, and everything that is
wrong. Add agent rule files so every harness can work on this repo.

_Exit test:_ this document set is merged; `AGENTS.md`/`CLAUDE.md` exist at
root.

### Phase 1 — Trust the build (CI + correctness)

The project cannot absorb contributors or agents while merges are ungated and
known races exist.

- ~~PR/`main` CI: protocol tests, `agent-runtime.test.mjs`, Linux Docker E2E on
  every PR; macOS E2E on a schedule or label (backlog §D1, §D3).~~ **Done.**
- Fix the correctness bugs that can crash or corrupt a running host: the
  shutdown data race on `LinuxBrowserHost`, force-unwraps in `visual compare`,
  the oversized `qa report`/`artifact.list` responses vs the 1 MiB frame,
  accept-loop error spin (backlog §A).
- Make `@eN` ref invalidation explicit in responses instead of a surprise
  `ELEMENT_NOT_FOUND` (backlog §A7).
- Web app gets `next build` + eslint in the same CI (backlog §D3).

_Exit test:_ a PR cannot merge with failing tests; the E2E suites pass on CI
runners, not just laptops; the known-crash list in the backlog §A is empty.

### Phase 2 — One host, written once (deduplication refactor)

The dominant maintenance hazard is that every command is implemented twice
(~340-line switch on macOS, ~280-line on Linux) plus duplicated validators,
error ladders, and constants. This phase extracts a shared `HostCore` so a
command is written once against a small `BrowserEngine` interface, with typed
errors end-to-end (backlog §B).

This is also the **prerequisite for Windows**: after it, a Windows port is one
new engine + one new transport backend, not a third copy of everything.

_Exit test:_ adding a hypothetical new verb touches one dispatch site; the
error-code mapping is a typed enum, not string matching; the capability matrix
(clipboard, network mock, PDF fidelity, …) is generated from code and asserted
in tests.

### Phase 3 — Distribution (v1.1: install like a real product)

"Deployed to multiple users who can actually use it" means:

- **macOS:** Developer ID signing + notarization + stapling; `.dmg` or signed
  zip; universal (arm64 + x86_64) binary; Homebrew tap → cask/formula.
- **Linux:** `curl -fsSL …/install.sh | sh` installer that downloads the right
  tarball, verifies checksums, and runs the existing preflight; publish the
  Docker `production` image to GHCR on every tag.
- **Everywhere:** `SHA256SUMS` (+ optional cosign) on all release assets;
  version unification (`git tag` = Info.plist = `--version` flag =
  `package.json`); a CHANGELOG generated per release; release automation
  (release-please or tag-driven notes).
- **npm wrapper** (`npx headless-browser` style) that downloads the platform
  binary — the cheapest path into JS-centric agent stacks. (Backlog §E.)

_Exit test:_ a new user on a clean macOS or Linux machine gets from zero to
`headless start` + first `visit` in under two minutes without touching a
compiler, and without a Gatekeeper override on macOS.

### Phase 4 — Agent ecosystem depth

Make Headless the obvious choice inside every harness:

- MCP: fix the flat 30 s timeout mismatch, decide the `stop`/`session close`
  exposure policy, add MCP protocol tests, ship copy-paste configs for Claude
  Code (`.mcp.json`), Cursor, Codex TOML — replacing the current hardcoded
  personal-VM example on the website (backlog §C, §F6).
- Skill: keep `.agents/skills/` as the canonical source; mirror/discover into
  `.claude/skills/` so Claude Code finds it natively.
- Capabilities doc generated from `CommandName.allCases` and asserted in tests
  so agents can trust `headless capabilities` (backlog §C4).
- Close the highest-value command gaps found in real agent use: trusted CDP
  mouse/key/text input is implemented on Linux; `--` end-of-options support is
  implemented so `fill` can type literal `--json`; response pagination for
  large reports remains (backlog §G).

_Exit test:_ a fresh Claude Code, Cursor, and Codex session can each discover
and drive Headless with zero manual prompting beyond repo checkout.

### Phase 5 — Website and docs as a product surface

- Deploy `apps/web` (Vercel or static export + CDN) with CI.
- Kill the three-copy content drift: docs prose and benchmark numbers come
  from single sources (benchmark emits JSON; site imports it; command tables
  generated from the CLI) (backlog §F).
- Add the missing pages: install, security model, MCP setup, command
  reference, changelog, platform matrix.
- Keep the generated benchmark current with the task-aware inspect flow before
  quoting any token number. The site imports the generated medians and carries
  their point-in-time caveat (backlog §F4).

_Exit test:_ site deploys on merge; every number and command on it is
generated or test-asserted; the "stale benchmark" warning is gone because the
benchmark is current.

### Phase W — Windows (stretch, after Phases 2–3)

Best-effort goal, explicitly **not required for "done"**. Prerequisite:
Phase 2's engine/transport split. Shape of the work (detailed in
[architecture-decisions §6](roadmap/architecture-decisions.md)):

- The Rust control-transport seam and secure Unix backend are implemented in
  [#140](https://github.com/LockInTime/headless/issues/140), preserving the
  shipping local-security contract while leaving the Windows backend explicit.
- Named-pipe transport with SID-based peer checks replacing the Unix socket.
- Win32 process/pipe layer for Chromium's `--remote-debugging-pipe` (HANDLE
  inheritance instead of fd 3/4).
- Windows artifact store backend (ACLs instead of POSIX modes).
- Chromium/Edge discovery via registry + Program Files; ffmpeg `.exe`
  discovery; winget manifest.
- Until then, the documented Windows answer is Docker Desktop/WSL2 with the
  published image (Phase 3 dependency).

_Exit test:_ the Linux E2E scenario passes on a Windows runner with the
Chromium engine; `winget install headless` works.

---

## 6. Definition of done

The idea is considered **done** — v2.0, ready to hand to many users — when all
of the following hold:

1. **Install:** package-manager installs on macOS (brew, notarized) and Linux
   (curl installer + GHCR image), each verifiable by checksum, each under two
   minutes on a clean machine.
2. **Trust:** every PR is CI-gated on both platforms; the backlog's
   correctness section (§A) is empty; security boundary claims in the README
   are each backed by a test.
3. **One contract:** command behavior is either identical across platforms or
   returns an explicit capability error; the matrix is generated and asserted.
4. **Agent-native:** any MCP-capable harness and any AGENTS.md-reading harness
   can drive Headless from a fresh checkout with no human glue; `headless
capabilities` is machine-accurate.
5. **Evidence current:** benchmark re-run on the shipping workflow; QA
   evidence regenerated for the release; website deployed and drift-free.
6. **Docs:** this roadmap's Phases 1–5 checked off, with Windows either
   shipped (bonus) or cleanly documented as Docker/WSL2.

Windows-native support is explicitly **not** part of "done" (user decision,
2026-08-04); it remains the headline stretch goal afterwards.

---

## 7. How to work on this repo

- Read [`AGENTS.md`](../AGENTS.md) (humans too — it is the concise contributor
  guide: build, test, conventions, safety rules).
- Never weaken an item in [what-is-excellent](roadmap/what-is-excellent.md)
  without a written decision in
  [architecture-decisions](roadmap/architecture-decisions.md).
- Every fix taken from the [backlog](roadmap/improvements-backlog.md) should
  check the item off in the same PR, and add the missing test named there.
- Keep the media policy: no binary fixtures in git except
  `docs/qa/evidence/`; new local evidence goes to `build/qa-evidence/`.
