# chromeless

Persistent browser control for agents, without Playwright scripts or screen
coordinates.

P2 uses the same CLI on both platforms:

- macOS 13+: visible WKWebView windows.
- Linux: sandboxed Chromium, headless by default or visible with `DISPLAY`.

## Agent workflow

```sh
chromeless start
chromeless session create qa
chromeless --session qa visit localhost:3000/designers/dashboard
chromeless --session qa inspect --interactive --text
chromeless --session qa record start --fps 10
chromeless --session qa tour --full-page
chromeless --session qa click --role button --name Continue
chromeless --session qa wait --url /next --settled
chromeless --session qa record stop --output dashboard-flow.mp4
chromeless --session qa screenshot --full-page --output next-page.png
chromeless --session qa qa report
chromeless --session qa console list --level error
chromeless --session qa network list --failed
chromeless --session qa styles get --role button --name Continue --property display
chromeless artifacts list
```

`inspect` returns roles, names, media URLs, decoded image/video dimensions,
load state, safety markers, bounds, and references such as `@e1`.
`capture-info` returns the browser surface, page state, action trace, and
recording state for an external recorder or QA harness.

When an action fails, use the on-demand diagnostic commands instead of an
interactive DevTools UI: `console list`, `network list|get`, `styles get`,
`cookies list`, and `storage list`. Cookie and storage values stay redacted
unless the host was deliberately started with `CHROMELESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`.

Run `chromeless help` for every command or `chromeless capabilities` for the
JSON capability contract.

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
./apps/chromeless/build.sh
./apps/chromeless/Chromeless.app/Contents/Resources/bin/chromeless help
```

Requires Xcode Command Line Tools. The build checks for Swift, Apple utilities,
and a compatible SDK before compiling.

### Linux

```sh
./apps/chromeless/build-linux.sh
apps/chromeless/build/linux/install-linux.sh
```

Only Docker is needed to build. The output includes a portable tarball and an
installer that checks Chromium and FFmpeg before copying both binaries.

Build an x86-64 binary from Apple Silicon with:

```sh
CHROMELESS_LINUX_PLATFORM=linux/amd64 ./apps/chromeless/build-linux.sh
```

## Tests

```sh
pnpm test                 # shared protocol/security suite
pnpm test:e2e:mac         # real WKWebView workflow
pnpm test:e2e:linux       # disposable Docker + sandboxed Chromium workflow
```

The Linux E2E container receives `SYS_ADMIN` so Chromium can initialize its
nested sandbox. Native VM deployment does not need that capability.

Run the repeatable comparison against Selenium and Puppeteer with:

```sh
./apps/chromeless/benchmark.sh 5
```

See [P2](apps/chromeless/docs/P2.md) for comparison, flow, networking, and MCP
behavior, and [benchmark](apps/chromeless/docs/BENCHMARK.md) for the method, limits,
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
- Page downloads are denied; only explicit Chromeless artifacts are written.
- Non-root, sandboxed Chromium on Linux.

Any process already running as the same OS user can access that user's browser
profile and socket. Run untrusted agents as separate OS users, and treat browser
output as potentially sensitive.

See [P0](apps/chromeless/docs/P0.md) for the control foundation,
[P1](apps/chromeless/docs/P1.md) for capture and diagnostics, and
[P2](apps/chromeless/docs/P2.md) for advanced QA workflows.
