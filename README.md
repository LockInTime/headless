# headless

Persistent browser control for agents, without Playwright scripts or screen
coordinates.

Headless began as a fork of
[antiwork/chromeless](https://github.com/antiwork/chromeless). With thanks to
Sahil Lavingia for the original foundation.

Supported platforms: macOS, Linux (including Ubuntu and the common Linux test
distros used in CI/Docker). Windows is not supported.

P2 uses the same CLI everywhere Headless runs:

- macOS 13+: visible WKWebView windows.
- Linux (Ubuntu and other distros): sandboxed Chromium, headless by default or
  visible with `DISPLAY`.

## Computer use comparison

Three common agent browser paths, scored **1–5** as qualitative capability
judgments (not lab benchmarks):

| Dimension | Coordinate CU (regular browser) | Scripted (PW / Puppeteer / Selenium) | Headless |
| --- | :---: | :---: | :---: |
| Targeting precision | 2 | 4 | 5 |
| Safety / blast radius | 2 | 3 | 5 |
| Evidence (shots, video, QA) | 3 | 3 | 5 |
| Agent surface (tokens / glue) | 2 | 3 | 5 |
| Setup friction | 3 | 3 | 4 |
| Platform coverage (host OS) | 5 | 5 | 4 |
| Desktop / OS reach | 5 | 1 | 1 |

- **Coordinate CU** — strong when the agent needs the whole desktop; weaker on
  precise web targeting (pixels drift), larger screenshot/prompt cost, and a
  broader OS blast radius. Runs on Windows, macOS, and Linux.
- **Scripted** — reliable selectors and driver APIs; more agent glue to write
  and maintain; evidence and security posture are usually bolted on. Broad
  host-OS support including Windows.
- **Headless** — semantic role/name/`@ref` actions, private socket + allowlisted
  commands, built-in record/screenshot/diagnostics; browser-only (no desktop).
  Runs on macOS and Linux (Ubuntu and common CI/test distros); Windows is the
  exception.

**Measured agent surface** (same P2 fixture flow, Docker ARM64, 17 Jul 2026 —
point-in-time): Headless warm **147** est. tokens vs Selenium **410** /
Puppeteer **499**. Full method and limits:
[BENCHMARK.md](apps/headless/docs/BENCHMARK.md).

## Agent workflow

```sh
headless start
headless session create qa
headless --session qa visit localhost:3000/designers/dashboard
headless --session qa inspect --interactive --text
headless --session qa record start --fps 10
headless --session qa tour --full-page
headless --session qa click --role button --name Continue
headless --session qa wait --url /next --settled
headless --session qa record stop --output dashboard-flow.mp4
headless --session qa screenshot --full-page --output next-page.png
headless --session qa qa report
headless --session qa console list --level error
headless --session qa network list --failed
headless --session qa styles get --role button --name Continue --property display
headless artifacts list
```

`inspect` returns roles, names, media URLs, decoded image/video dimensions,
load state, safety markers, bounds, and references such as `@e1`.
`capture-info` returns the browser surface, page state, action trace, and
recording state for an external recorder or QA harness.

When an action fails, use the on-demand diagnostic commands instead of an
interactive DevTools UI: `console list`, `network list|get`, `styles get`,
`cookies list`, and `storage list`. Cookie and storage values stay redacted
unless the host was deliberately started with `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`.

Run `headless help` for every command or `headless capabilities` for the
JSON capability contract.

## Agent skill

This repository ships a portable browser-computer-use skill at
`.agents/skills/headless-computer-use/`. Skills-aware agents can invoke it as
`$headless-computer-use` to select a native or Docker runtime, drive the
snapshot-and-semantic-action loop, capture evidence, diagnose failures, and
clean up the session safely. If an agent does not auto-discover repository
skills, point it directly at that `SKILL.md` file.

Example prompt: `Use $headless-computer-use to launch this project's browser,
test the signup flow end to end, and return verified screenshot, video, and QA
report evidence.`

## Evidence capture

Built-in recording captures browser pixels to MP4 through FFmpeg. It works in
headless Linux and does not include OS chrome or audio. For an OS recorder, OBS,
or a CI recorder, use `capture-info` to get the window or browser process and
keep using the same navigation commands.

Screenshots support the viewport, full page, or one element. `inspect` exposes
rendered media with its source, decoded dimensions, load and playback state,
safety marker, poster, and accessible name;
screenshots and recordings capture the visible media pixels.

## Build

### macOS

```sh
./apps/headless/build.sh
./apps/headless/Headless.app/Contents/Resources/bin/headless help
```

Requires Xcode Command Line Tools. The build checks for Swift, Apple utilities,
and a compatible SDK before compiling.

### Linux

```sh
./apps/headless/build-linux.sh
apps/headless/build/linux/install-linux.sh
```

Only Docker is needed to build. The output includes a portable tarball and an
installer that checks Chromium and FFmpeg before copying the binaries. The
Docker image is the supported self-contained Linux runtime and uses Debian's
Chromium binary at `/usr/lib/chromium/chromium`.

For a native Linux install, use a real Chromium binary supplied by the Linux
distribution. Ubuntu's `/snap/bin/chromium` launcher resolves to
`/usr/bin/snap`; it is rejected because repeated navigation is unreliable over
Chromium's inherited DevTools pipe. If automatic detection is unsuitable, set
`HEADLESS_CHROMIUM_EXECUTABLE` to an absolute, executable, non-Snap binary.
Invalid overrides fail closed instead of silently selecting a different
browser. Verify the exact selection before starting the host:

```sh
headless runtime
headless start
```

Build an x86-64 binary from Apple Silicon with:

```sh
HEADLESS_LINUX_PLATFORM=linux/amd64 ./apps/headless/build-linux.sh
```

### GitHub Releases

Pushing a version tag publishes downloadable packages:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Assets: macOS `Headless.app` zip, Linux amd64/arm64 tarballs. See the Actions
`Release` workflow and the release notes on each tag for install caveats
(Gatekeeper; Linux Chromium/FFmpeg).

## Tests

```sh
pnpm test                 # shared protocol/security suite
pnpm test:e2e:mac         # real WKWebView workflow
pnpm test:e2e:linux       # disposable Docker + sandboxed Chromium workflow
```

The Linux E2E container receives `SYS_ADMIN` so Chromium can initialize its
nested sandbox. Native VM deployment does not need that capability. A passing
Docker run retains verified PNG, MP4, JSON, and checksum evidence under
`apps/headless/build/qa-evidence/`.

Run the repeatable comparison against Selenium and Puppeteer with:

```sh
./apps/headless/benchmark.sh 5
```

See [P2](apps/headless/docs/P2.md) for comparison, flow, networking, and MCP
behavior, and [benchmark](apps/headless/docs/BENCHMARK.md) for the method, limits,
and measured results.

## Security boundary

- No TCP control or Chromium debugger port.
- `0600` Unix socket in a `0700` per-user directory, with peer-UID checks.
- Chromium control over inherited fd 3/4 pipes.
- Isolated browser helpers and allowlisted, bounded commands.
- `0600` artifacts in a `0700` per-user directory; no path traversal or
  overwrite.
- HTTP/HTTPS navigation only; no file URLs, credentials, external application
  schemes, arbitrary JavaScript, or shell execution.
- An agent session starts on a clean page and abandons any previously opened
  local-file or application page before it can be inspected.
- Remote executables, installers, scripts, libraries, and disk images are
  blocked by extension. Archives are reported as a caution and are never
  downloaded or unpacked.
- Page downloads are denied; only explicit Headless artifacts are written.
- Non-root, sandboxed Chromium on Linux.

Any process already running as the same OS user can access that user's browser
profile and socket. Run untrusted agents as separate OS users, and treat browser
output as potentially sensitive.

See [P0](apps/headless/docs/P0.md) for the control foundation,
[P1](apps/headless/docs/P1.md) for capture and diagnostics, and
[P2](apps/headless/docs/P2.md) for advanced QA workflows.
