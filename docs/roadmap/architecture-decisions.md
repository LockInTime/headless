# Architecture decisions

Companion to [ROADMAP.md](../ROADMAP.md). This document records the keep/change
decisions for the codebase as it stands in August 2026, with reasons, so the
next months of work don't re-litigate them. Format per decision: **Decision →
Status → Rationale → Consequences / revisit trigger.**

---

## 1. Core language: keep Swift (decided, with a revisit trigger)

**Decision:** the core stays Swift — the shared `HeadlessProtocol` library,
the CLI, the MCP server, and both hosts. No Rust/Go rewrite.

**Status:** decided 2026-08-04 (owner delegated the recommendation; this is
it).

**Rationale:**

- The investment is already amortized: ~7.5k lines of working, tested Swift
  spanning both platforms, with zero third-party dependencies and a QA
  evidence trail proving behavior. A rewrite resets all of that for a benefit
  that is mostly hypothetical.
- The macOS host is irreducibly Swift (Cocoa/WebKit). A Rust/Go core would
  _add_ a language boundary (FFI or IPC between the Swift app and the new
  core) rather than remove one.
- Swift on Linux is genuinely fine here and proven in this repo: static
  stdlib builds in Docker (`Dockerfile.linux`), stripped binaries, no runtime
  to install.
- The real pain attributed to "Swift" is actually **duplication** (two hand-
  written hosts) and **stringly-typed errors** — fixable in place (decision
  §3), far cheaper than a rewrite.
- Contributor-pool concerns are mitigated by the agent-first reality: this
  repo is built to be worked on by coding agents, and the rule files +
  contract docs matter more than language familiarity.

**Costs accepted:**

- Windows: Swift-on-Windows exists (the Browser Company ships it) but the
  toolchain is rougher than Rust/Go. Accepted because Windows is a stretch
  goal (roadmap Phase W), and Phase 2's engine split confines the port to
  transport + process-spawn + artifact backends.
- Binary distribution stays per-platform build scripts rather than
  `cargo`/`goreleaser` conveniences. Phase 3 does this work once.

**Revisit trigger:** if Windows-native is ever promoted to must-have _and_ a
spike shows Swift-on-Windows cannot pass the Linux E2E scenario within ~2
weeks of effort, revisit with a concrete proposal: keep the WKWebView app in
Swift, move `HeadlessProtocol` + Chromium host to Rust, talk over the existing
JSON protocol (which is language-neutral by design and makes this migration
tractable later). Do not drift into a rewrite without hitting this trigger.

## 2. Monorepo layout: keep, with one addition

**Decision:** keep the pnpm monorepo (`apps/headless` Swift package,
`apps/web` Next.js, empty `packages/`). Node is only the workflow driver and
the web app; the product has no runtime Node dependency — keep it that way.

**Addition:** when benchmark/docs generation lands (roadmap Phase 5),
generated machine-readable outputs (benchmark JSON, command tables) live in
`packages/` or `apps/headless/build/` with explicit provenance, so the web app
imports data instead of transcribing it.

## 3. Two hosts → one `HostCore` + `BrowserEngine` interface (change, Phase 2)

**Status:** implemented 2026-08-10.

**Decision:** extract everything currently duplicated between
`apps/headless/main.swift` (macOS, ~340-line dispatch) and
`apps/headless/LinuxHost/main.swift` (~280-line dispatch) into a shared
`HostCore` in `HeadlessProtocol` (or a sibling target):

- one command dispatcher, one flow replay loop, one screenshot-series loop,
  one trace ring buffer, one report bundler, one error→code mapping;
- a small `BrowserEngine` protocol implemented twice: `WebKitEngine` (wraps
  `AgentBridge`) and `ChromiumEngine` (wraps `BrowserProcess`), later
  `ChromiumEngine` on Windows;
- **typed errors** (`HostError` enum carrying the protocol error code)
  replacing the `message.contains("ELEMENT_NOT_FOUND")` string matching on
  both hosts and in `AgentBridge.swift:416-418`;
- single definitions for the constants currently written 2–4×: blocked/caution
  extension sets (Swift _and_ the JS copy get a cross-check test), screenshot
  bounds, artifact charset, local-address list, inspect/console/storage/scroll
  enums, numeric bounds (CLI and validator currently disagree — e.g. scroll
  amount `>0` vs `>=0.1`).

**Rationale:** every new verb is currently written twice and the compiler only
checks enum exhaustiveness, not behavioral equivalence; silent divergence has
already happened (report `page` shape, capture-info shape, tour timeout, JPEG
quality path, PDF raster-vs-vector). This refactor is the precondition for
Windows and for keeping principle "one contract" true.

**Non-goal:** merging the engines' _capabilities_. Divergent capability stays
explicit (`UNSUPPORTED_CAPABILITY`); the point is that the _common_ path is
single-sourced and the divergent one is declared, generated into
`capabilities`, and asserted by tests.

**Capability-matrix consequence (implemented 2026-08-10):** each engine owns
one exhaustive profile used by both `headless capabilities` and the active
host's additive `ping.capabilities` field. Profiles partition every protocol
command into supported and unsupported sets and declare behavioral differences
that cannot be made identical without weakening an engine. This compatible
response addition does not bump protocol 0.5.

## 4. Wire protocol: keep as-is, version bump only when necessary

**Decision:** keep newline-delimited JSON over the private Unix socket,
version `"0.5"`, strict decoding, per-command parameter allow-lists, 1 MiB
frames. The protocol is deliberately language- and transport-neutral — that
neutrality is what keeps both the Windows port and the (rejected-for-now)
Rust option cheap.

**Amendments planned (backlog §A5, §G3):**

- Response-side bounding: `qa report` and `artifact.list` can exceed the 1 MiB
  frame today and surface a misleading `INVALID_REQUEST`. Add pagination
  (`--limit/--cursor`) or server-side truncation with `truncated: true`,
  consistent with the pruning philosophy. This is a compatible addition.
- Response `id` must echo the request `id` and clients should verify it
  (today failure paths return `id:"unknown"` and the client never checks).

**Rejected:** gRPC/protobuf, TCP+TLS, HTTP. They add dependencies, listeners,
or both, against principle 6 (local-first security).

## 5. Transport & isolation: keep Unix socket + peer-UID; abstract for Phase W

**Decision:** keep `/tmp/headless-<uid>` `0700`/`0600` + `getpeereid` /
`SO_PEERCRED` as the Unix mechanism. For Windows (Phase W), define a
`ControlTransport` seam in Phase 2 so a named-pipe + SID-ACL backend can slot
in without touching `HostCore`.

Known hardening items stay on the backlog (§A): accept-loop error spin,
hard-coded `SO_PEERCRED = 17`, `HEADLESS_SOCKET` asymmetry, no peer-UID test.

**Decision (unchanged from P0):** remote control remains deferred until it has
authentication, authorization, and transport security. SSH + stdio MCP remains
the only remote story. A hosted service is out of scope for this roadmap
(owner decision 2026-08-04: package-manager distribution, no cloud offering).

## 6. Windows strategy: Chromium-host port behind the Phase 2 seam (deferred)

**Decision:** Windows is a stretch goal (owner decision 2026-08-04:
"later / best-effort", not required for done). When attempted:

- **Engine:** the Chromium engine only. The WKWebView host is never ported.
- **Port surface (known and bounded):** `Transport.swift` (named pipes +
  SID peer check), `Artifacts.swift` (ACLs instead of POSIX modes; `O_EXCL`
  equivalent via `CREATE_NEW`), the spawn half of `BrowserProcess.swift`
  (`CreateProcess` + inheritable HANDLEs for `--remote-debugging-pipe` —
  Chromium on Windows takes handles via `STARTUPINFO`, not fd 3/4), the I/O
  half of `CDP.swift` (overlapped I/O instead of `poll`), signal handling
  (console control handler), `ChromiumRuntime.swift` (registry + Program
  Files + Edge discovery, `;` PATH splitting), ffmpeg `.exe` discovery, and
  re-authoring the shell scripts (the E2E suite is POSIX sh).
- **Portable already:** `Protocol.swift`, `CLI.swift`, `AgentRuntime.swift`
  (the JS is engine-agnostic), `Diagnostics.swift`, `Flows.swift`,
  `CaptureFormats.swift`, `ScreenshotSeries.swift`, `Recording.swift` (modulo
  discovery), `MCP/main.swift`.
- **Interim answer (Phase 3):** published Docker image + WSL2 documented as
  the supported Windows path.

## 7. macOS engine: keep WKWebView as the visible-browser experience

**Decision:** keep the WKWebView host as macOS's default engine. It is the
differentiated experience (a real visible browser window a human can watch the
agent drive, passkey story, clipboard) and it exercises the "same contract,
two engines" discipline that keeps the protocol honest.

**Acknowledged limits (stay documented, not "fixed"):** diagnostics are
best-effort (no full network event stream), no network emulation/mocking,
raster PDF. If agent demand ever requires full-fidelity diagnostics on macOS,
the answer is offering the Chromium engine on macOS as an _additional_
runtime behind the same CLI (the Linux host already builds on macOS-adjacent
Foundation APIs) — not hacking WKWebView. That would be a new decision entry.

**Resolved (backlog §B8, decision §18):** the page-world QA diagnostics bridge
is documented as detectable and forgeable; the host fixes its provenance,
bounds it per document, and marks its evidence untrusted. Agent actions and
inspection remain in `WKContentWorld`.

## 8. In-page action model: synthetic events now, real input later (Linux)

**Decision:** today `click`/`fill`/`press` are synthetic DOM events from the
isolated world (`AgentRuntime.swift:492-537`) on both engines — no trusted-
event semantics, no hover/drag, `press` only special-cases Enter/Space.
Keep this as the _portable baseline_, and in Phase 4 add real input on the
Chromium engine via CDP `Input.dispatchKeyEvent`/`dispatchMouseEvent`, exposed
as the same verbs (upgrade, not new commands), with WKWebView staying on the
synthetic path as a declared capability difference.

**Rationale:** synthetic events fail on real-world widgets (rich editors,
canvas apps, key-repeat handlers); Chromium can do better cheaply; the
contract machinery from Phase 2 makes the divergence declarable.

## 9. Recording: keep the ffmpeg pipe design; revisit codec

**Decision:** keep `BrowserRecording`'s design (host-captured PNG frames piped
to an allow-listed ffmpeg; browser-frames-only recording scope). Revisit the
**mpeg4 (Part 2) codec choice** in Phase 3: it exists to avoid x264
licensing, but produces large, poorly-compatible files. Evaluate defaulting
MP4 to H.264 where a system encoder is available (VideoToolbox on macOS) or
making WebM/VP9 the recommended default in docs, keeping mpeg4 as fallback.
Add palettegen to the GIF path (quality, cheap).

## 10. Agent runtime: one embedded JS source is correct; injection cost is not

**Decision:** keep the single shared `agentRuntimeJavaScript` string as the
one implementation of page-side semantics for every engine (it is what makes
"same contract" real). Fix the delivery mechanics (backlog §B7):

- Linux re-creates the isolated world and re-sends ~30 KB of JS on **every**
  evaluate — 3 CDP round trips per command, polled at 20 Hz by `wait`
  (`BrowserProcess.swift:777-834`). Cache the world/context per navigation and
  use `Page.addScriptToEvaluateOnNewDocument`.
- macOS re-sends the same source per call through `callAsyncJavaScript`;
  install once per navigation via `WKUserScript` in the agent content world.
- Extract the JS to a `.js` resource compiled into the binary (SwiftPM
  resources) so tooling/tests stop regex-extracting it from a Swift string
  literal (`Tests/agent-runtime.test.mjs`'s `/#"""…"""#/` coupling).

**Status:** implemented 2026-08-10. The source is now the compiled
`Resources/AgentRuntime.js`; WebKit installs it in `HeadlessAgent` at document
start, while Chromium installs it with
`Page.addScriptToEvaluateOnNewDocument`, caches the isolated context for the
document, and invalidates or retries it across navigation races. Distribution
scripts install the generated resource bundle alongside each host executable.

## 11. Session model: document shared-profile reality; isolation is a future opt-in

**Decision:** sessions are windows (macOS) / tabs (Linux) sharing one
profile — cookies and storage are shared across sessions on both engines. This
matches the "persistent logged-in browser" product idea, so keep it as the
default, but **document it loudly** (it reads like an isolation boundary and
is not). If per-session isolation is wanted later, the Chromium engine gets
`Target.createBrowserContext` behind a `session create --isolated` flag; the
WKWebView engine would declare `UNSUPPORTED_CAPABILITY` or use non-persistent
`WKWebsiteDataStore`. New decision entry required when scheduled.

## 12. Versioning: unify on the git tag (change, Phase 3)

**Status:** implemented 2026-08-12.

**Decision:** the git tag becomes the single version source: injected at build
time (already works via `HEADLESS_VERSION`), reported by a new `headless
--version`/`version` command and in `ping`, matched by `package.json`, MCP
`serverInfo` (today it reports protocol version "0.5" as the server version),
and the website. Protocol version stays independent (wire compatibility ≠
product version). CHANGELOG generated per tag.

## 13. Web app: keep Next.js; move content to generated sources (Phase 5)

**Decision:** keep `apps/web` on Next.js/Tailwind — no framework change. The
architectural change is **content provenance**: benchmark numbers, command
tables, and docs prose must be imported from repo artifacts (benchmark JSON
emitted by `benchmark.sh`, command reference generated from `CLI.swift`'s
parser/help, shared markdown) instead of hand-copied into TSX/TS in three
places. Also: delete dead visual code (`side-rays.tsx`/`ogl`, unused assets),
reconsider shipping two WebGL bundles for decoration, add deploy pipeline +
CI, metadata/sitemap/404. Details: backlog §F.

## 14. Testing architecture: promote the conformance suite (Phase 1–2)

**Status:** implemented 2026-08-10.

**Decision:** keep the three-layer shape (protocol unit suite, jsdom runtime
suite, per-platform E2E), and add the missing keystone: a **cross-engine
conformance runner** — one scenario file executed against both engines
asserting identical JSON shapes (or declared capability errors), replacing
today’s hand-mirrored `macos-e2e.sh`/`linux-e2e.sh` assertions that have
already drifted. The hand-rolled no-XCTest runner is fine (it keeps Linux
docker runs trivial); don't churn it to a framework.

The portable `Tests/conformance.sh` scenario is invoked by both platform E2E
suites. It asserts the same response fields for shared behavior and consults
the generated engine profile only for declared differences, so adding an
engine or changing a shared response requires updating one executable contract.

## 15. Distribution architecture (Phase 3, owner-decided)

**Decision (owner, 2026-08-04):** package managers, no hosted service.
Concretely: Homebrew tap (notarized), Linux curl installer + GHCR-published
Docker image, npm binary-wrapper for JS-stack reach, winget only with Phase W.
Checksums on everything; keep release CI's script-reuse design (the workflow
calls the same `build.sh`/`test.sh` a developer runs — preserve that
property when adding PR CI).

## 16. CLI values preserve shell argument boundaries (decided)

**Decision:** global `--json` and `--session` options are recognized only
before the first `--` sentinel. The sentinel is removed before command
parsing. `fill` accepts its text as exactly one shell argument rather than
joining multiple arguments with inserted spaces.

**Status:** decided 2026-08-10 while resolving backlog §A6.

**Rationale:** typed values are data and must reach the browser byte-for-byte
as represented by the Swift string. Searching the whole argv for global flags
could silently remove literal text, while joining tokens normalized tabs and
repeated spaces. Standard shell quoting plus an end-of-options sentinel makes
the boundary explicit and testable.

**Consequences:** callers quote multi-word fill text and place `--` before a
value containing a literal `--json` or `--session`. This changes only CLI
parsing; the wire protocol and protocol version remain unchanged.

## 17. MCP exposes the full remote-command surface with pessimistic annotations

**Decision:** keep `stop` and `session close` callable through the single
argv-based MCP tool. Describe the tool as state-mutating and explicitly set
the MCP annotations `readOnlyHint: false`, `destructiveHint: true`,
`idempotentHint: false`, and `openWorldHint: true`.

**Status:** decided 2026-08-10 while resolving backlog §C2.

**Rationale:** the MCP adapter deliberately mirrors the remote CLI surface.
Special-casing two valid remote commands in the adapter would create policy
drift and prevent an MCP operator from recovering a wedged host or cleaning up
a session. The same tool already navigates, clicks, fills, and changes browser
state, so describing it as universally "safe" was inaccurate. Because MCP
annotations apply to the whole tool rather than individual argv variants, the
tool must advertise the risk of its most destructive valid invocation.

**Consequences:** trusted MCP clients can require confirmation for the tool,
and callers can still invoke the complete browser-command surface. Annotations
are risk metadata, not authorization; the private socket, peer-UID check,
protocol validation, and host-enforced safety rules remain the security
boundary. Local-only commands such as `start` remain rejected by the adapter.
This changes MCP discovery metadata only and does not bump the wire protocol.

## 18. WebKit page diagnostics are explicitly untrusted evidence

**Decision:** keep the macOS console/fetch/XHR observer in the page content
world, while keeping every agent action and inspection helper in the named
`HeadlessAgent` isolated world. Treat all diagnostic output on both engines as
untrusted page evidence. The macOS host assigns the fixed source
`webkit-page-bridge`, ignores a page's claimed source, accepts at most 500
bridge messages per document, and reports rejected messages as truncation.

**Status:** decided 2026-08-10 while resolving backlog §B8.

**Rationale:** WKWebView exposes neither page console messages nor a complete
subresource network stream to an isolated content world. Patching the page's
console, fetch, and XHR APIs is therefore best-effort observation, not a
security boundary: the page can detect, replace, invoke, or spam that bridge.
Removing it would discard useful QA evidence; presenting its messages without
trust metadata would let a hostile page counterfeit host facts. Fixed native
provenance, a native acceptance cap, and pervasive untrusted markers preserve
the evidence without overstating its authority.

**Consequences:** protocol 0.5 adds `untrustedContent: true` to diagnostic
reports, events, derived issues, console listings, and network listings/details.
Consumers must not interpret diagnostic text or URLs as instructions. Native
navigation and download events use the same conservative marker because they
can contain page-selected URLs. A hostile-page macOS E2E test locks source
override, the 500-event bound, and truncation reporting.

## 19. macOS agent startup does not steal focus by default

**Decision:** windows created by CLI-launched macOS agent hosts are visible but
ordered behind the user's current application. `headless start --foreground`
and `--background` override presentation for a newly launched host. Users can
change the persistent default with the validated `headless config set
startup-presentation foreground|background` command and inspect it with
`headless config get startup-presentation`. Presentation choices never reorder
a host that is already running. Direct GUI launches retain normal foreground
behavior.

**Status:** implemented 2026-08-12.

**Rationale:** persistent agent automation should not interrupt the user's
keyboard and visual focus merely because a host or session starts. Keeping the
window visible preserves observability, screenshots, recording, and WebKit
rendering without making background automation disruptive. Making foreground
activation explicit still supports interactive demonstrations and debugging.

**Consequences:** automatic startup and `headless start` use the configured
presentation on macOS, falling back to background. Session windows created by
that host follow the same policy. Launch flags take precedence over the saved
setting. Linux behavior and the wire protocol are unchanged; presentation
configuration fails there with `UNSUPPORTED_CAPABILITY`. macOS E2E coverage
asserts the real frontmost process for configured background and foreground
startup, session creation, running-host no-op behavior, and launch overrides.

## 20. Developer ID releases omit unprovisioned passkey entitlement

**Decision:** direct macOS releases are universal Developer ID Application
builds with hardened runtime, secure timestamps, notarization, and stapling.
They omit `com.apple.developer.web-browser.public-key-credential` by default.
The build accepts that restricted entitlement only when an Apple-approved
provisioning profile and entitlement file are both supplied explicitly for
`com.headless.app`.

**Status:** implemented 2026-08-12 for Phase 3 distribution.

**Rationale:** Apple's Developer ID capability set does not generally include
the restricted web-browser passkey entitlement. Claiming it without matching
provisioning approval can make macOS terminate the app and can fail
notarization. Shipping a signed app that launches reliably is stronger than
advertising a passkey path the distribution identity cannot support. The host
already detects its own entitlement and hides WebAuthn when absent so sites can
offer password, phone, or other fallback sign-in.

**Consequences:** normal Homebrew and ZIP installs do not expose WKWebView
passkeys. Apple approval can enable them later without changing the protocol:
the release operator supplies both provisioning inputs and the existing runtime
check detects the granted entitlement. Tagged builds fail rather than falling
back to ad-hoc signing or skipping notarization. Pull-request dry runs still
exercise the universal package path with an ad-hoc signature and no Apple
credentials.

---

## Decision log

| #   | Decision                                                    | Status            | Date       |
| --- | ----------------------------------------------------------- | ----------------- | ---------- |
| 1   | Keep Swift core; Rust only via revisit trigger              | Decided           | 2026-08-04 |
| 3   | Extract HostCore + BrowserEngine, typed errors              | Implemented       | 2026-08-10 |
| 5   | Remote stays SSH-only; no cloud offering                    | Decided (owner)   | 2026-08-04 |
| 6   | Windows = stretch via Chromium engine; WSL2/Docker interim  | Decided (owner)   | 2026-08-04 |
| 8   | Real CDP input on Linux as capability upgrade               | Planned (Phase 4) | 2026-08-04 |
| 12  | Version unification on git tag                              | Implemented       | 2026-08-04 |
| 14  | Run one conformance scenario against every engine           | Implemented       | 2026-08-10 |
| 15  | Package-manager distribution set                            | Decided (owner)   | 2026-08-04 |
| 16  | Preserve CLI value boundaries with `--` and shell quoting   | Decided           | 2026-08-10 |
| 17  | Keep full MCP surface; annotate its maximum risk            | Decided           | 2026-08-10 |
| 18  | Treat WebKit page diagnostics as bounded untrusted evidence | Decided           | 2026-08-10 |
| 19  | Keep macOS agent startup behind the current app             | Implemented       | 2026-08-12 |
| 20  | Omit passkeys unless Apple provisions Developer ID release  | Implemented       | 2026-08-12 |

New decisions append here with the same format.
