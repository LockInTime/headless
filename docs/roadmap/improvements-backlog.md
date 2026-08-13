# Improvements backlog — full information dump

Companion to [ROADMAP.md](../ROADMAP.md). Every known defect, gap, and missing
feature as of 2026-08-04, with file/line references, so engineers (human or
agent) can pick items up without re-deriving the analysis. Items marked
**[exists]** are already partially present in the codebase and need finishing
or hardening, not inventing.

Conventions: paths are relative to repo root; `HP/` =
`apps/headless/Sources/HeadlessProtocol/`. Check items off here in the same PR
that fixes them, and add the named missing test.

**Every open item below is also a GitHub issue**, linked inline and labelled
[`backlog`](https://github.com/LockInTime/headless/labels/backlog). Issues carry
type/area/priority labels, sit in the milestone for their roadmap phase, and
appear on the [Headless Roadmap board](https://github.com/orgs/LockInTime/projects/1),
so you can pick work up from either the tracker or this file. Keep both in sync:
when you fix an item, check it off here and close the issue in the same PR.

---

## §A — Correctness & robustness (Phase 1: fix first)

**A1. Shutdown data race on the Linux host.** ([#12](https://github.com/LockInTime/headless/issues/12)) `LinuxBrowserHost` is
`@unchecked Sendable` with unlocked `sessions`/`trace`/`recordings`/
`activeFlows` (`apps/headless/LinuxHost/main.swift:9-12`). Normal commands are
serialized by the transport's `requestQueue`, but `shutdown` deliberately
bypasses that queue (`HP/Transport.swift:213-218`) and `host.stop()`
(`LinuxHost/main.swift:24-30`) mutates that state concurrently with an
in-flight command. macOS guards the same state (`onAgentMain` +
`recordingsLock`, `apps/headless/main.swift:807-808,1307-1328`); Linux does
not. ~~Fix: a host-state lock (or actor) used by both paths; keep the
bypass-the-queue property for shutdown.~~ **Done:** all four containers are
behind `stateLock`, taken only around collection access and never across
browser I/O, so teardown still cannot be delayed by a stalled command. `stop()`
is idempotent, snapshots and clears under the lock, then tears down outside it.
Session and recording registration re-check `stopping` under the lock, so a
recording started mid-teardown can no longer outlive the host as an orphaned
FFmpeg process. Regression test in `Tests/linux-e2e.sh`: an active recording
plus a tour in flight while `stop` runs, asserting a clean host exit and a
clean restart.

**A2. Force-unwraps in a long-lived host.** ([#13](https://github.com/LockInTime/headless/issues/13)) `visual compare` handlers do
`request.parameters["before"]!.stringValue!` on both hosts
(`LinuxHost/main.swift:239-240`, `main.swift:1175-1176`). Safe only while
`validate()` runs first; any future path that skips validation crashes the
host and kills every session. ~~Replace with guarded extraction returning
`MISSING_PARAMETER`.~~ **Done** on both hosts, plus the nil-check-then-force-
unwrap in `HP/Diagnostics.swift:155`. The validator makes these parameters
required, so the guards are defence in depth; `ProtocolTests` now asserts that
requirement so the guards can never become the only thing holding the path up.

**A3. Oversized responses break the 1 MiB frame.** ([#14](https://github.com/LockInTime/headless/issues/14)) `qa report` can hold 500
events × ~4 KiB ≈ 2 MB; `artifact.list` is unbounded. `encodeLine` throws
inside `handleClient` and the client receives a misleading
`INVALID_REQUEST` (`HP/Transport.swift:219-227`). ~~Fix: response-side bounding —
pagination (`--limit/--cursor`) or truncation with `truncated: true` — per
architecture decision §4. Test: generate >1 MiB of events, assert a bounded,
well-formed response.~~ **Done** by truncation: `qa report` bounds its issue and
event arrays by byte budget while keeping `summary` counts accurate over the
whole buffer, `artifacts list` returns the newest 250 with `total`/`omitted`,
and both report `truncated`. A response that still cannot be framed now fails
`RESPONSE_TOO_LARGE` instead of `INVALID_REQUEST`. Tests assert both responses
encode within `headlessMaximumMessageBytes`. Cursor pagination remains the
richer answer and is tracked separately (§G3).

**A4. Accept-loop error spin.** ([#15](https://github.com/LockInTime/headless/issues/15)) All `accept()` errors are swallowed with
`continue` (`HP/Transport.swift:180-184`); persistent EMFILE becomes a hot
loop. ~~Add backoff + a fatal threshold.~~ **Done:** failures back off from
50 ms to 1 s and the listener stops after 64 consecutive failures rather than
burning a core while silently refusing every agent.

**A5. `@eN` refs silently invalidated by every snapshot.** ([#16](https://github.com/LockInTime/headless/issues/16)) The `current` ref
map is reset on each `snapshot()` (`HP/AgentRuntime.swift:376`), so a
`--context summary` (max 8 elements) invalidates all refs from a prior
`full`; the agent later gets a bare `ELEMENT_NOT_FOUND`. Meanwhile
`currentRegions` is _never_ reset and grows for the page lifetime. ~~Decide the
contract (likely: refs from the latest inspection only — already the skill's
teaching), then (a) make the error say _why_ ("ref expired; re-inspect"),
(b) reset regions consistently on navigation, (c) document in P1.md. Test:
inspect-full → inspect-summary → click stale `@eN` asserts the new error.~~
**Done.** The contract is now explicit and asymmetric on purpose: `@eN` is
latest-inspection-only, `@rN` stays resolvable so the outline-then-scope
workflow survives across calls. Failures name the cause — `expired`, `unknown`,
or `detached` — instead of an anonymous `ELEMENT_NOT_FOUND`. Region tracking is
bounded at 256 oldest-first rather than growing for the page lifetime, which
also releases the strong references it was holding to detached nodes.
Documented in P1 under "Reference lifetime"; covered in
`Tests/agent-runtime.test.mjs`.

**A6. `--json`/`--session` stripped from anywhere in argv.** ([#17](https://github.com/LockInTime/headless/issues/17)) Global-option
stripping (`HP/CLI.swift:46-49`) happens before subcommand parsing, so
`headless fill @e1 pass --json to API` silently drops `--json` from typed
text; `fill` also joins args with single spaces destroying whitespace
(`CLI.swift:83-88`). ~~Add a `--` end-of-options sentinel, only strip globals
before it, and pass the fill value as one argument.~~ **Done:** global options
are stripped only before the first `--`; `fill` now requires one quoted text
argument and preserves its whitespace exactly. Protocol coverage includes
literal `--json`/`--session`, tabs, double spaces, and the quoting boundary.

**A7. Client never verifies response `id`.** ([#18](https://github.com/LockInTime/headless/issues/18)) Failure paths return
`id:"unknown"` (`HP/Transport.swift:201,222`); `LocalSocketClient.send`
doesn't check correlation. ~~Echo the request id everywhere and assert
client-side.~~ **Done:** the host echoes the id as soon as it can decode one,
so validation failures are correlated too, and the client rejects any other
id. `CommandResponse.unknownRequestIdentifier` is the one documented
exception, for replies where the host could not read the request at all —
those still have to reach the caller with their reason.

**A8. CDP O(n²) buffering.** ([#19](https://github.com/LockInTime/headless/issues/19)) ~~`receiveText` rescans the whole buffer and
`removeFirst`s per 8 KiB read (`LinuxHost/CDP.swift:229-256`); a 30 MB
base64 screenshot triggers thousands of full scans under a 128 MiB cap.
Track a scan offset / use a ring buffer.~~ **Done:** a shared incremental NUL
message buffer scans each appended region once and amortizes prefix compaction;
protocol coverage feeds it a 30 MiB message in the host's 8 KiB read chunks.

**A9. Misc hardening (smaller, same phase).** ([#20](https://github.com/LockInTime/headless/issues/20))

- ~~`ChromiumChildProcess.stop()` can busy-wait forever post-SIGKILL
  (`LinuxHost/BrowserProcess.swift:38`); bound it.~~
- ~~`SO_PEERCRED` hard-coded as `17` + hand-rolled `ucred`
  (`HP/Transport.swift:372-378`); use the libc constant and add the missing
  **peer-UID test** (the most security-critical untested branch).~~
- ~~`Diagnostics.headersValue` uses `prefix(64)` on a Dictionary —
  non-deterministic header survival (`HP/Diagnostics.swift:213`).~~
- ~~`ArtifactStore.finalize` has a `fileExists`+`move` TOCTOU vs the `O_EXCL`
  used elsewhere (`HP/Artifacts.swift:148-151`).~~
- ~~`Recording.status()` reads `process.isRunning` cross-thread; recording init
  busy-polls 3 s for the first frame (`HP/Recording.swift:71-88,186-215`).~~
- ~~`stringHeaders` stringifies non-string header values via
  `String(describing:)` (`LinuxHost/BrowserProcess.swift:854-858`).~~
- ~~`flow run` executes up to 200 steps inside one socket request while the CLI
  timeout is 15 s (`main.swift:1224`, `HeadlessCLI/main.swift:113`) — stream
  progress or raise/derive the client timeout.~~
- ~~`qa` subcommand validates trailing args before checking the subcommand is
  known → wrong error for `headless qa bogus --x` (`HP/CLI.swift:115-119`).~~
- ~~macOS non-agent nav policy hands unknown schemes to `NSWorkspace.open` and
  allows `data:`/`blob:`/`javascript:` when agent control is off
  (`main.swift:710-716`) — fine for humans, but document why, or tighten.~~

**Done:** child teardown has a post-SIGKILL bound; Linux uses the libc socket
constant and the cross-UID test; header selection is sorted and malformed CDP
values are dropped; artifact finalization uses atomic no-replace linking;
recording startup uses a short six-attempt exponential backoff and status
tracks process termination under its lock; flow replay gets the transport's
125-second bound; QA errors are ordered correctly; and the visible macOS app
enforces web-only navigation in manual as well as agent-controlled use.

## §B — Structure & contract (Phase 2)

**B1. HostCore extraction** ([#21](https://github.com/LockInTime/headless/issues/21)) — ~~the headline refactor; full spec in
[architecture-decisions §3](architecture-decisions.md). Duplicated pairs to
collapse (verified line ranges): dispatch switches (`main.swift:949-1291` /
`LinuxHost/main.swift:65-343`), screenshot-series loops (`main.swift:911-945`
/ `LinuxHost/main.swift:32-63`), trace ring (`main.swift:1293-1305` /
`LinuxHost/main.swift:345-357`), flow replay (`main.swift:1204-1230` /
`LinuxHost/main.swift:262-284`), report bundle (`main.swift:1189-1203` /
`LinuxHost/main.swift:250-261` — shapes already diverged), error ladders
(`main.swift:1243-1290` / `LinuxHost/main.swift:293-342`), sensitive-diag
gate, target validation (3 copies + JS), screenshot bounds, syscall shims
(`Transport.swift:387-407` / `CDP.swift:278-288`).~~ **Done:** `HostCore` now
owns the dispatcher, lifecycle state, flows, traces, captures, recordings,
reports, artifacts, and common error mapping. Thin WebKit and Chromium
adapters implement one `BrowserEngineSession` contract, with a fake-engine
protocol test locking the shared path. Element-target conversion, the
sensitive-diagnostics gate, and screenshot safety bounds are shared as well.

**B2. Typed errors end-to-end.** ([#22](https://github.com/LockInTime/headless/issues/22)) ~~Replace `message.contains("ELEMENT_NOT_FOUND")`
string matching (both hosts; `Host/AgentBridge.swift:416-418`) with an error
enum carrying the protocol code.~~ **Done:** the isolated runtime assigns an
allowlisted error code, WebKit and CDP return the same bounded JSON envelope,
and both hosts propagate a shared `HostError` whose typed code owns the
protocol response and recovery suggestion. Unknown page codes fail closed as
`OPERATION_FAILED`; no host classifies human-readable error text.

**B3. Single-source constants + drift tests.** ([#23](https://github.com/LockInTime/headless/issues/23)) ~~Blocked/caution extensions
exist in Swift (`HP/Protocol.swift:576-591`) and JS
(`HP/AgentRuntime.swift:17-21`) with no cross-check; artifact charset written
4×; local-address list 3×; CLI vs validator bounds disagree (scroll amount
`>0` vs `>=0.1`, `CLI.swift:248` / `Protocol.swift:261`; network emulate
unbounded in CLI, `CLI.swift:449` / `Protocol.swift:396-398`). One definition
each + a test asserting the JS copy contains the Swift set.~~ **Done:** name
characters, local hosts, and numeric bounds have one shared definition; the
CLI enforces the validator's scroll and network ranges; and protocol coverage
parses both JavaScript extension sets and requires exact equality with Swift.

**B4. Dead code removal.** ([#24](https://github.com/LockInTime/headless/issues/24)) ~~`screenshotSeriesPoints(from:)`
(`HP/ScreenshotSeries.swift:74-76`), `JSONValue.foundationObject`
(`HP/Protocol.swift:670-679`), discarded `timeout` param
(`LinuxHost/BrowserProcess.swift:777-778`) — either honor it (tour expects
65 s) or delete it, unreachable non-fullPage PDF branch
(`BrowserProcess.swift:483-486`), effectively-no-op `--json` flag
(`HeadlessCLI/main.swift:145`) — implement human-readable output or remove
the flag from help, `jsonValue(from:)` duplicate
(`AgentBridge.swift:428-441`).~~ **Done:** removed the unused screenshot and
Foundation conversion paths, made both hosts share `JSONValue.foundationValue`,
honored the bounded Linux evaluation timeout, deleted the unreachable PDF
branch, and hid the backward-compatible no-op `--json` parser flag from help.

**B5. `pruneToBudget` quality.** ([#25](https://github.com/LockInTime/headless/issues/25)) ~~Hand-rolled 2-pass fixed point
(`HP/AgentRuntime.swift:348-352`), O(n²) re-encoding per trim, pop-largest-
_last_-element heuristic misses large mid-array items
(`AgentRuntime.swift:367-369`), text-chop fallback untested. Rework with a
size-estimating single pass; add unit tests in the jsdom suite.~~ **Done:**
each candidate is measured once, largest entries are pruned regardless of
position while retained order is stable, text uses a byte-budgeted prefix
search, and jsdom locks the mid-array and text-fallback cases.

**B6. Declared capability matrix.** ([#26](https://github.com/LockInTime/headless/issues/26)) ~~Silent per-platform divergences to either
fix or promote to declared differences asserted in tests: PDF raster (macOS,
`Host/AgentBridge.swift:236-250`) vs vector (`Page.printToPDF`,
`BrowserProcess.swift:471-496`); element-screenshot coordinate space viewport
(macOS `AgentBridge.swift:173`) vs document+beyond-viewport (Linux
`BrowserProcess.swift:443-459`); tour timeout 65 s vs 125 s; JPEG encoder
paths; cookies shape (host-filtered on macOS `AgentBridge.swift:306-348` vs
full `Network.getCookies` fields on Linux `BrowserProcess.swift:606-632`);
capture-info/report shapes; `back` with no history errors on Linux
(`BrowserProcess.swift:404-414`) but silently succeeds on macOS
(`main.swift:1054-1055`); Linux recording pauses during navigation
(`recordingPausedUntil`, `BrowserProcess.swift:729-733`) while macOS records
through it; `press` length enforced in bridge only on macOS
(`AgentBridge.swift:73`); Linux `qa report` flush hack
(`BrowserProcess.swift:521`). Generate `capabilities` from code
(`CLI.swift:648-682` is a hand-written literal today) and assert it.~~ **Done:**
WebKit and Chromium now declare exhaustive command sets and typed profiles for
every audited difference. The CLI document and host ping output are generated
from those profiles and the protocol/format enums. Empty-history `back`, tour
timeouts, and key validation are aligned; irreducible engine behavior is
explicit and regression-tested.

**B7. Runtime injection cost** ([#27](https://github.com/LockInTime/headless/issues/27)) — ~~cache the isolated world / install runtime
per-navigation instead of per-call on both engines; extract the JS to a
compiled resource. Spec in [architecture-decisions §10](architecture-decisions.md).
(`BrowserProcess.swift:777-834`, `AgentBridge.swift:382-420`,
`Tests/agent-runtime.test.mjs` regex extraction.)~~ **Done:** both engines
install the compiled JavaScript resource at document start, Linux caches and
invalidates its isolated context with one stale-context retry, and release /
installer paths carry the SwiftPM resource bundle.

**B8. QA diagnostics bridge isolation (macOS).** ([#28](https://github.com/LockInTime/headless/issues/28)) ~~Page-world injection is
detectable/forgeable/spammable by a hostile page
(`Host/QADiagnosticsBridge.swift:5-93`, `main.swift:233-236`) while P0 claims
isolated-world helpers. Move what's possible; mark the rest untrusted. See
architecture decision §7.~~ **Done:** agent actions remain in the isolated
world; the unavoidable page-world observer is documented, host-attributed,
bounded per document, and all diagnostic evidence is marked untrusted in
protocol 0.5. A hostile WKWebView fixture proves spoofed provenance is ignored
and spam is truncated.

## §C — MCP & agent surface (Phases 1/4)

**C1. Timeout parity.** ([#29](https://github.com/LockInTime/headless/issues/29)) MCP uses flat 30 s except tour/series
(`apps/headless/MCP/main.swift:70-72`); CLI derives from `--timeout`
(`HeadlessCLI/main.swift:104-114`). `wait --timeout 90000` works in CLI, dies
via MCP. ~~Derive identically.~~ **Done:** both adapters now call the same
`HeadlessProtocol.requestTimeout(for:)` helper. Coverage locks the ordinary,
wait-derived, tour, screenshot-series, screenshot, and recording-stop cases.

**C2. Destructive verbs over MCP.** ([#30](https://github.com/LockInTime/headless/issues/30)) ~~`stop` (shutdown) and `session close` are
callable though the tool description says "safe"; decide policy (deny, or
annotate) and test it.~~ **Done:** architecture decision §17 keeps the complete
remote CLI surface and pessimistically annotates the single tool as mutating,
destructive, non-idempotent, and open-world. The stdio integration suite locks
the metadata and proves both destructive commands still reach the local host.

**C3. Zero MCP tests** ([#31](https://github.com/LockInTime/headless/issues/31)) — ~~the only coverage is inside `qa-videos.sh`. Add a
stdio harness test: initialize / tools/list / tools/call / malformed line /
oversized line / local-command rejection (`MCP/main.swift:64-66`).~~ **Done:**
`HeadlessMCPTests` drives the built stdio process through every named case and
uses a private local socket server to verify a real browser-command round trip.

**C4. Machine-accurate `capabilities`** ([#32](https://github.com/LockInTime/headless/issues/32)) — ~~generate from `CommandName.allCases`
and the engine matrix (see B6) so agents can trust it.~~ **Done:** the document
derives commands from `CommandName.allCases`, engine profiles from
`BrowserEngineName.allCases`, and capture formats and bounds from their runtime
definitions. The protocol suite proves both command partitions are exhaustive
and every declared engine has exactly one profile.

**C5. Harness onboarding [exists: skill content].** ([#33](https://github.com/LockInTime/headless/issues/33)) ~~Root `AGENTS.md` +
`CLAUDE.md`; mirror the skill into `.claude/skills/` so Claude Code
auto-discovers it; ship project-scoped Claude Code, Cursor, and Codex MCP
configs; replace the site's hardcoded personal SSH target; and complete the
OpenAI skill metadata.~~ **Done:** the canonical skill is symlinked into
Claude's discovery path, all three clients use one repository-relative stdio
launcher, the setup guide includes native and Docker variants, and web lint
checks the configs for drift.

**C6. Input fidelity (Phase 4).** ([#34](https://github.com/LockInTime/headless/issues/34)) Real CDP input on Linux
(`Input.dispatchKeyEvent`/`dispatchMouseEvent`) behind the same verbs; today
both engines dispatch synthetic DOM events and `press` special-cases only
Enter/Space (`HP/AgentRuntime.swift:492-537`). Declared divergence per B6.

**C7. Considered-and-worth-designing (not committed):** ([#35](https://github.com/LockInTime/headless/issues/35)) hover/drag verbs;
`select` for dropdowns; scoped `evaluate` never (see what-is-excellent §3);
per-session isolated profiles (`session create --isolated`, architecture §11);
response-body inspection stays denied (P1.md:134) unless a gated design lands.

## §D — CI & testing (Phase 1)

**D1. PR/`main` CI** — ~~absent; only tag-triggered release existed
(`.github/workflows/release.yml`; PRs #4–#8 merged ungated).~~ **Done:**
`.github/workflows/ci.yml` runs on every PR and `main` push — static checks
(shell syntax across sh/bash/zsh, `docs/qa/evidence` checksum verification,
whitespace), `pnpm test:runtime`, the protocol suite on Linux
(`swift:6.1-bookworm` container) and macOS, and `linux-docker.sh` with the QA
evidence uploaded as an artifact. `macos-e2e.sh` is gated to nightly cron,
`workflow_dispatch`, or the `macos-e2e` PR label because it needs a GUI
session and mutates user defaults (`Tests/macos-e2e.sh:26-40`). All jobs
invoke the same scripts a developer runs locally, matching release.yml.

Follow-ups: mark the jobs required in branch protection (repo setting, not
code); consider arm64 Linux E2E on PRs (release covers it on tags); revisit
whether the macOS E2E can become a per-PR gate once runtime is measured.

**D2. Known test gaps (from code audit).** ([#36](https://github.com/LockInTime/headless/issues/36)) No tests for: peer-UID rejection
(A9), MCP (C3), `Recording.swift` (ffmpeg args per format/quality, discovery
rejection, drop-frame abort at `consecutiveFailures`, stop timeout),
`VisualComparison`, `Flows.swift` — including the security property that
`fill` is non-replayable, `ArtifactStore.read` bounds/non-regular-file,
`capabilities` accuracy, `navigation-blocked`/`download-blocked`
classification, oversized-request-over-socket behavior, JS runtime
`click`/`fill`/`press`/`scroll`/`state`/`tour`/`screenshotPlan`/`dedupePoints`
(80-cap, 96px threshold), budget text-chop fallback, `@eN` invalidation
(A5), plus ~20 CLI commands with no parse test (list in the audit:
tour/back/reload/capture-info/artifacts/qa/performance/animations/report/
flow start-stop/network emulate/mock clear/session ops/status/stop/start/help).
Also tighten `rejectsUnexpectedRequestFields` (`ProtocolTests.swift:109-114`)
which currently passes for the wrong reason.

**Progress:** MCP stdio coverage now exercises C3 end to end. The audited CLI
command matrix is covered, and the unexpected-field test first proves its
current-version control request decodes before adding the forbidden field.
Artifact read boundaries, non-regular-file rejection, flow replay safety, and
visual-comparison invocation are now covered as well. Runtime coverage now
locks click/fill/press/scroll/state/tour behavior, unsafe-link rejection,
screenshot-plan caps and 96 px deduplication, budget text fallback, and stale
element-reference errors. Recording coverage now locks every format/quality
argument mapping, strict executable discovery, consecutive-failure aborts, and
bounded stop timeouts; capabilities and oversized socket requests are covered.
Linux CI also connects through a deliberately different uid and requires
`PEER_DENIED`; Linux and macOS E2E assert `navigation-blocked` and
`download-blocked` diagnostics respectively. **Done:** every gap named in D2
now has direct regression coverage.

**D3. Web CI:** ~~`next build` + eslint on PR (site can break invisibly today).~~
**Done** — the `web` job in `ci.yml` runs `pnpm --filter @headless/web lint`
and `build`.

**D4. Cross-engine conformance runner** ([#37](https://github.com/LockInTime/headless/issues/37)) ~~(architecture §14) replacing drifted
hand-mirrored E2E assertions (e.g. `macos-e2e.sh:231` vs `linux-e2e.sh:157`).~~
**Done:** one portable scenario now runs unchanged inside both real-engine E2E
suites. It locks common JSON fields across lifecycle, navigation, inspection,
diagnostics, capture, flows, reports, and errors, branching only through the
declared capability matrix for intentional differences.

**D5. Benchmark refresh discipline [exists: benchmark.sh].** ([#38](https://github.com/LockInTime/headless/issues/38)) ~~Emit JSON
results artifact; re-run with the task-aware flow; report repeat-count medians
instead of single samples.~~ **Done:** the benchmark validates and preserves
every sample in a provenance-bearing JSON document, reports per-metric medians,
and the refreshed five-repeat snapshot includes task-aware action inspection.

## §E — Distribution (Phase 3)

Owner-decided scope: package managers, no hosted service.

- **E1.** [x] ([#39](https://github.com/LockInTime/headless/issues/39)) ~~macOS Developer ID signing + notarization + stapling; universal binary;
  Homebrew tap/cask; resolve passkey provisioning.~~ **Done:** tag builds fail
  closed unless every arm64/x86_64 executable is hardened-runtime Developer ID
  signed and securely timestamped, accepted by `notarytool`, stapled, and
  Gatekeeper-valid. A checksum-pinned cask is published by the tap's own
  repository-scoped workflow. The restricted passkey entitlement is omitted unless Apple
  approves a matching `com.headless.app` provisioning profile; the existing
  fallback remains active otherwise.
- **E2.** [x] ([#40](https://github.com/LockInTime/headless/issues/40)) ~~Linux `curl | sh` installer wrapping the existing tarball +
  preflight; align its FFmpeg policy with the runtime allow-list; single-source
  Snap detection.~~ **Done:** the release bootstrap resolves amd64/arm64,
  verifies the versioned tarball against `SHA256SUMS`, rejects archive-shape
  drift, and delegates to the packaged installer. That installer now calls the
  product's Chromium runtime resolver and restricts FFmpeg to the recording
  allow-list or a validated absolute override. Offline tests cover latest and
  pinned versions, checksums, archive contents, architecture, and overrides.
- **E3.** [x] ([#41](https://github.com/LockInTime/headless/issues/41)) ~~Publish the Docker `production` image to GHCR on tag; this is also the
  interim Windows story.~~ **Done:** packaging PRs build and smoke-test the
  non-root production target with no exposed ports. Version tags publish an
  amd64/arm64 GHCR manifest with SemVer, source-tag, commit-SHA, and `latest`
  references plus OCI provenance and an SBOM, then pull by digest and rerun the
  smoke suite before the GitHub Release is created.
- **E4.** ([#42](https://github.com/LockInTime/headless/issues/42)) ~~`SHA256SUMS` for all release assets — the QA evidence bundle already ships
  sums; releases don't.~~ **Done:** the publish job requires all three named
  regular package files, generates `SHA256SUMS` atomically, verifies it, and
  attaches the manifest to the release. Cosign remains optional future work.
- **E5.** [x] ([#43](https://github.com/LockInTime/headless/issues/43)) ~~npm wrapper package (binary download shim) for `npx` reach.~~
  **Done:** `@lockintime/headless` exposes the CLI and MCP adapter, downloads
  only its matching official release, verifies the exact `SHA256SUMS` entry,
  rejects unsafe archives, validates the embedded version, and reuses a
  private per-user cache. CI locks the installer and packed npm contents.
- **E6.** [x] ([#44](https://github.com/LockInTime/headless/issues/44)) Version unification + `headless --version` + CHANGELOG + release
  automation (architecture §12). `package.json` says 0.0.0, tags say 1.0.x,
  default `HEADLESS_VERSION` is 1.0.0.
- **E7.** ([#45](https://github.com/LockInTime/headless/issues/45)) Cut a release: everything since v1.0.2 (capture formats, context
  pruning) is unreleased.
- **E8.** [x] ([#46](https://github.com/LockInTime/headless/issues/46)) ~~`NSAllowsArbitraryLoads` is blanket-true
  (`build.sh:86-90`); scope it (localhost exception) if WKWebView allows.~~
  **Done:** native app networking retains ATS while the HTTP compatibility
  exception is limited to `WKWebView`; the bundle build asserts this boundary.

## §F — Website & docs (Phase 5)

- **F1. Deploy pipeline is invisible to the repo** ([#47](https://github.com/LockInTime/headless/issues/47)) — the site _is_ live at
  `https://headless-web-pi.vercel.app` (set as the repo homepage) via Vercel's
  GitHub integration, but nothing in the tree records that: no `vercel.json`,
  no deploy docs, no preview-URL comment on PRs, and the temporary
  `*-pi.vercel.app` hostname suggests no custom domain. Make the deployment
  reproducible and reviewable — check in the project config, document the
  hosting in `AGENTS.md`, and decide on a domain. Keep the existing headers/CSP
  in `next.config.ts`; consider a nonce so `unsafe-inline` can be dropped.
- **F2. Content provenance** ([#48](https://github.com/LockInTime/headless/issues/48)) — benchmark numbers hand-copied in
  `app/page.tsx:26-38`, `components/efficiency-chart.tsx:26-31`,
  `components/benchmark-chart.tsx:21-26` (+ date in two places); docs prose
  triplicated across `app/docs/page.tsx`, `components/docs-markdown.ts`, and
  `README.md`, already diverging. Import from generated artifacts (D5, B6).
- **F3. Missing pages:** ([#49](https://github.com/LockInTime/headless/issues/49)) install (README's build/install section is absent
  from the site entirely), security model, MCP setup, full command reference
  (~30 commands; site lists 4 groups), changelog/version indicator, platform
  matrix, the README's comparison table (strongest positioning content, not
  on site). Plus `robots.txt`, `sitemap`, OG metadata, per-page `metadata`,
  404 page.
- **F4. Stale-benchmark honesty:** ([#50](https://github.com/LockInTime/headless/issues/50)) site quotes pre-`--task` numbers while
  marketing `--task`, and drops BENCHMARK.md's re-run warning; headline says
  "Measured, not claimed." Fix by refresh (D5) or by carrying the caveat.
- **F5. Dead weight:** ([#51](https://github.com/LockInTime/headless/issues/51)) `components/ui/side-rays.tsx` + `ogl` dep (unused),
  `public/scan-dashboard.png` (unreferenced), leftover shadcn `.dark` block in
  `globals.css`, 8 unused button variants; two WebGL stacks (~700 KB) for
  decoration — `PixelBlast` still creates GL contexts under
  `prefers-reduced-motion` (CSS-only hide) and its closing instance has no
  reduced-motion rule; Recharts (~150 KB) for 4 static bars. Also
  `scan-frame.tsx` hardcodes pixel bounds tied to a committed github.com
  screenshot (drift + trademark question).
- **F6. Fix the Cursor config snippet** ([#52](https://github.com/LockInTime/headless/issues/52)) — ~~hardcodes `ssh hermes-vm`
  (`components/docs-markdown.ts:57-64`), unusable by anyone else.~~ **Done:**
  the website serializes the checked-in project config that uses the portable
  repository launcher.
- **F7. Docs debt in-repo:** ([#53](https://github.com/LockInTime/headless/issues/53)) README states P1/P2 features but there is no
  single command reference doc; P1.md should document the `@eN` invalidation
  contract (A5) and the shared-profile session model (architecture §11);
  `.gitignore:18-23` still references `apps/chromeless/`.

## §G — Feature ideas (informed dump; schedule via roadmap phases) ([#54](https://github.com/LockInTime/headless/issues/54))

Gathered from the audit and product thinking; none are committed until they
get an architecture-decision entry:

- **G1. `headless doctor`** — one command validating runtime, ffmpeg, socket
  dir, permissions, and printing fix hints (pieces exist across
  `install-linux.sh`, `runtime`, sandbox `doctor`).
- **G2. Structured host logging** — today host stderr goes to `/dev/null`
  unless `HEADLESS_HOST_LOG` is set (`HeadlessCLI/main.swift`); startup
  failures are near-invisible. Default to a rotating log in the runtime dir.
- **G3. Response pagination primitives** (with A3) — cursor pattern reusable
  by `console list`, `network list`, `artifacts list`.
- **G4. Session metadata** — `session list` returning current URL/title/age;
  cheap, big agent QoL.
- **G5. `wait --network-idle`** — Chromium engine has the events; declared
  capability on WKWebView.
- **G6. Element screenshot on Linux `--by-region @rN`** — region-scoped series
  capture, pairs naturally with the pruning ladder.
- **G7. Trace export** — `capture-info` already returns an action trace;
  `report create` bundles it; a `--format junit`/markdown export would slot
  into CI comments.
- **G8. Multi-host coexistence** — one socket per user today
  (`/tmp/headless-<uid>/host.sock`); named hosts (`--host qa`) would allow
  parallel isolated instances; today requires manual `HEADLESS_SOCKET`.
- **G9. Cookie import for authenticated QA** — deliberately absent today;
  needs a security design (gated like sensitive diagnostics) before any work.
- **G10. Per-session isolated browser contexts** — architecture §11.

---

## Priority key

Phase 1 = §A + §C1–C3 + §D1–D3. Phase 2 = §B + §D4. Phase 3 = §E.
Phase 4 = §C4–C7 + §G1–G5. Phase 5 = §F + §D5. Phase W = architecture §6.
