# What is excellent — do not change

Companion to [ROADMAP.md](../ROADMAP.md). These are the parts of Headless where
the *idea* is right and the implementation expresses it well. They are the
product's identity. None of them may be weakened, "simplified away", or
regressed by a refactor without a written decision recorded in
[architecture-decisions.md](architecture-decisions.md).

Each item states the idea, where it lives, and what specifically must be
preserved. (Known implementation bugs *inside* these areas are still fixable —
they're listed in the [backlog](improvements-backlog.md) — but the fix must
preserve the contract described here.)

---

## 1. Semantic targeting instead of coordinates or selectors

**Idea:** agents act on `--role button --name Continue` or a ref (`@e1`,
`@r4`) handed back by the latest inspection — never on pixel coordinates,
never on CSS selectors they invented.

**Where:** the agent runtime
(`apps/headless/Sources/HeadlessProtocol/AgentRuntime.swift`), the `click`/
`fill`/`styles`/`screenshot` target grammar in `CLI.swift`, and the skill rule
"Never invent a ref or guess coordinates"
(`.agents/skills/headless-computer-use/SKILL.md`).

**Preserve:** refs are observations from the host, not durable selectors;
role/name is the preferred stable form; action hints (`actions: ["click"]`)
only ever advertise verbs the protocol can actually execute
(`AgentRuntime.swift:67-88` deliberately emits no `select`/`upload`/`slide` —
there is even a test grepping the JS for this, `ProtocolTests.swift:602-604`).

## 2. Progressive context pruning — the token budget as a first-class contract

**Idea:** a page is never dumped into a prompt. Inspection starts at
`--context summary`, escalates through `outline` (region refs) → scoped
`text`/`actions` via `--within @rN`, ranked by `--task`, bounded by `--limit`
/ `--budget` / `--depth`; `full --text` stays available as the explicit
escape hatch. Every focused response reports `contextStats` (bytes, estimated
tokens, budget applied) and `omitted` counts, so pruning is visible, never
silent.

**Where:** `AgentRuntime.swift` (contexts, ranking, `pruneToBudget`),
`CLI.swift:168-215`, `Protocol.swift` inspect validation, documented in
`apps/headless/docs/P1.md`. Measured: 48,428 bytes → 895 bytes (94.5 % token
reduction) on the 120-section fixture
(`docs/qa/evidence/context-pruning-results.json`).

**Preserve:** the five-context ladder; explicit `omitted`/`truncated`
accounting; defaults that keep responses small; the principle that no future
feature returns unbounded output. This is the product's measurable moat.

## 3. Fail-closed safety at the host, not in the prompt

**Idea:** the safety rules are enforced by the host process, so a
prompt-injected or confused agent *cannot* violate them.

**Where and what (each of these is a hard contract):**
- **No arbitrary JavaScript verb.** The protocol exposes only fixed runtime
  functions; `capabilities` advertises `arbitraryJavaScript: false`.
- **HTTP/HTTPS only.** `normalizedWebURL` / `agentMayNavigate`
  (`Protocol.swift:530-609`): no `file:`, `javascript:`, `data:`, external app
  schemes, or credential-bearing URLs; bare hosts default to https except
  local dev addresses. Enforced at *three* layers: visit, host navigation
  policy (macOS `decidePolicyFor`, Linux frame-event enforcement), and the
  in-page click guard.
- **Downloads denied.** `Browser.setDownloadBehavior deny` on Linux
  (`BrowserProcess.swift:196`); WKDownload cancelled on macOS
  (`main.swift:733-748`). Dangerous remote extensions hard-blocked (25-entry
  list), archives surfaced as `caution` (`Protocol.swift:576-591`).
- **Private control plane.** `0600` socket in a `0700` per-user dir, peer-UID
  check (`getpeereid`/`SO_PEERCRED`), 1 MiB frame cap, strict request
  decoding with per-command parameter allow-lists (`Transport.swift`,
  `Protocol.swift:154-411`). No TCP listener, no Chromium debug port —
  DevTools rides the inherited fd-3/4 pipe.
- **Artifact discipline.** Names validated (no paths, no leading dot, charset,
  extension allow-list); `O_EXCL` create at `0600` in a `0700` owner-checked
  root; never overwrite; the only read primitive is bounded and root-confined
  (`Artifacts.swift`).
- **Sensitive values gated twice.** Cookie/storage *values* need both
  `--values` and a host started with `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`;
  auth/cookie/token/secret headers and URL credentials are always redacted
  (`Diagnostics.swift:204-235`).
- **Typed values never persisted.** Flow recording excludes `fill` — replay
  files can never contain credentials (`Flows.swift:25-27`).
- **Linux never weakens the sandbox.** No `--no-sandbox`, refuses root
  (`BrowserProcess.swift:161-163`); Snap Chromium rejected *before launch* by
  path and shebang sniffing rather than failing mysteriously later
  (`ChromiumRuntime.swift:167-184`).
- **Agent takeover starts clean.** A window showing a local file when the
  agent attaches is reloaded to the start page before the agent can read it
  (`main.swift:461-471`).

**Preserve:** deny-by-default; every one of these stays host-enforced. Adding
an opt-in (like the sensitive-diagnostics env var) is acceptable; moving
enforcement into documentation or prompts is not.

## 4. Untrusted-content marking

**Idea:** all page-derived text (names, snippets, console lines, network
URLs) is evidence, not instructions, and the protocol says so on the wire:
every inspection result carries `untrustedContent: true`
(`AgentRuntime.swift:393`), and the skill's `references/safety.md` teaches the
matching agent behavior (preserve evidence, report, don't obey).

**Preserve:** the marker plus the paired prose. This is the practical
prompt-injection defense and reviewers rely on it.

## 5. Evidence-first culture

**Idea:** claims ship with reproducible proof.

**Where:**
- `docs/qa/evidence/` — 11 recorded scenario videos + JSON + `SHA256SUMS`,
  regenerated by `apps/headless/Tests/qa-videos.sh` in disposable Docker.
- E2E suites assert *artifact truth*, not just exit codes: `file(1)` magic,
  `ffprobe` codec/duration, framemd5 unique-frame counts (video isn't a still),
  PNG IHDR height parsing (full-page really is taller), `0600` modes, no-TCP
  assertions via `lsof`/`/proc/net/tcp`.
- The media policy: no binary fixtures in git except that one evidence dir;
  local runs write to gitignored `build/qa-evidence/` (`P1.md:154-162`).

**Preserve:** the policy and the assert-the-artifact style. New features add a
scenario, not just a unit test.

## 6. Honest benchmarking

**Idea:** the benchmark (`apps/headless/docs/BENCHMARK.md`,
`benchmark.sh`) states exactly what it measures (workflow source bytes / 4 as
an *agent-surface* proxy — explicitly "not billed LLM tokens"), publishes the
dimensions it *loses* (Puppeteer is faster on wall time), refuses to claim
unmeasured wins (flows), marks results as point-in-time, and even carries a
self-deprecating staleness warning ("re-run before quoting"). The qualitative
README comparison table has a spec that forbids presenting it as a lab result
and forbids claiming an overall win (`docs/superpowers/specs/2026-07-18-…`).

**Preserve:** this candor is rare and is itself a feature. Numbers may be
refreshed; the caveat culture may not be dropped. (The one violation — the
website quoting stale numbers without the staleness warning — is backlog §F4.)

## 7. One CLI contract across engines, with explicit capability errors

**Idea:** the same commands, JSON shapes, and help text on macOS and Linux;
when an engine can't do something, it says `UNSUPPORTED_CAPABILITY` with a
suggestion (macOS network mocking, Linux clipboard) instead of pretending
(`main.swift:1231-1232`, `LinuxHost/main.swift:141-143`, P2.md:59-61).

**Preserve:** never ship a silent partial emulation. (Existing *accidental*
divergences — PDF raster vs vector, screenshot coordinate spaces — are bugs to
fix or to promote into declared capabilities: backlog §B6.)

## 8. The phased contract docs (P0 → P1 → P2)

**Idea:** each phase doc is a contract: acceptance workflow, security
boundaries, explicit deferrals ("remote control is deferred until it has
authentication"), and known limitations stated plainly (macOS diagnostics are
best-effort; response bodies deliberately not exposed; recorder doesn't
capture OS audio). `apps/headless/docs/P0.md`, `P1.md`, `P2.md`.

**Preserve:** the format. Future phases (this roadmap's Phase 1–5, W) should
be written the same way: contract first, with deferrals and limitations named.

## 9. The agent skill and its safety doctrine

**Idea:** `.agents/skills/headless-computer-use/` teaches an agent the whole
discipline: anti-overclaim rules up front, the 8-step interaction loop
(inspect summary first, escalate only as needed, re-inspect after navigation),
observation priority (structured inspect before screenshots — "screenshots as
evidence, not as the coordinate system"), a failure protocol that separates
product defects from environment failures, confirmation-required actions,
secrets hygiene, and "label mocked evidence". Plus a hardened Docker sandbox
wrapper (`scripts/headless-sandbox.sh`) with basename-only copy-out and
no-overwrite rules.

**Preserve:** the doctrine text and the sandbox script's restraint. Discovery
should improve (Phase 4), content should stay.

## 10. MCP as a thin argv adapter

**Idea:** `headless-mcp` (`apps/headless/MCP/main.swift`, 81 lines) exposes
**one tool** whose input is the CLI argv. The MCP surface *is* the CLI
surface — zero schema drift, every new command instantly available to every
MCP client, stdio-only with no TCP listener, remote via plain SSH.

**Preserve:** the single-tool argv design and the no-listener stance. (Timeout
mismatch and destructive-verb exposure are backlog §C.)

## 11. Small-surface, dependency-free core

**Idea:** the entire product is one SwiftPM package with **zero third-party
Swift dependencies** — Foundation + system frameworks only. External tools
(Chromium, ffmpeg) are resolved from explicit allow-listed absolute paths,
never `PATH` (`Recording.swift:219-239`). Supply-chain surface ≈ 0.

**Preserve:** adding a Swift dependency requires an architecture-decision
entry; executable discovery stays allow-listed.

## 12. Structured, machine-checked inputs everywhere

**Idea:** identifiers, artifact names, URLs, formats, bounds — every input has
a validator with limits chosen and written down (1 MiB frames, 64 MP
screenshots, 80-shot series with `truncated`+`totalPoints`, 200-step flows,
500-event diagnostics ring, 64 KiB mock bodies, printable-ASCII content-type
blocking CRLF injection). Strict decoding rejects unknown fields and unknown
parameters per command.

**Preserve:** new inputs get the same treatment; bounds stay documented in the
phase docs. (Consolidating the duplicated validator constants is backlog §B —
allowed, as long as the limits themselves survive.)

---

## Summary for reviewers

If a PR touches any of the twelve areas above, the review question is not
"does it work?" but "does the contract survive?". When in doubt, the contract
wins over cleverness, performance, and even consistency.
