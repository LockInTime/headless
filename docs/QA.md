# Headless QA evidence

This evidence layer exercises the shipped Linux CLI, the existing fixture server, and the bundled Chromium runtime in Docker. It does not use host Chromium or Snap Chromium.

## Run it

From the repository root:

```sh
apps/headless/Tests/qa-videos.sh
```

To choose a new absolute output path:

```sh
HEADLESS_QA_VIDEO_DIR=/absolute/path/to/evidence apps/headless/Tests/qa-videos.sh
```

Docker is the only host dependency. The script builds the `test` target from `apps/headless/Dockerfile.linux`, adds Node, Xvfb, xterm, and X11 inspection tools in a derived QA image, then starts the container with:

```sh
docker run --rm --shm-size=1g --cap-add=SYS_ADMIN \
  -e HEADLESS_EVIDENCE_DIR=/evidence \
  -v "$REPOSITORY_ROOT:/workspace:ro" \
  -v "$EVIDENCE_DIR:/evidence" \
  headless-qa-video-runtime \
  /workspace/apps/headless/Tests/qa-videos.sh --inside
```

`SYS_ADMIN` is limited to the disposable container so Chromium can use its namespace sandbox. Chromium remains the packaged `/usr/lib/chromium/chromium` and uses the inherited DevTools pipe. The fixture command is:

```sh
node /workspace/apps/headless/Tests/fixture-server.mjs
```

## Feature map

| Evidence | Supporting artifacts | Feature and representative commands |
| --- | --- | --- |
| [Runtime selection and Snap rejection](qa/evidence/01-runtime-selection-snap-rejection.mp4) | [Probe results](qa/evidence/media-probe.json) and [test results](qa/evidence/test-results.json) | Bundled runtime selection with `headless runtime`; explicit Snap rejection with `HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium headless runtime`; capabilities output |
| [Startup, session, and navigation](qa/evidence/02-startup-session-navigation.mp4) | [Probe results](qa/evidence/media-probe.json) | `headless start`, `session create qa`, dashboard and details visits, `wait`, `reload`, `back`, and a full-page tour |
| [Screenshots and visual comparison](qa/evidence/03-screenshots-visual-comparison.mp4) | [Probe results](qa/evidence/media-probe.json), [before](qa/evidence/visual-before.png), [after](qa/evidence/visual-after.png), [full page](qa/evidence/visual-full-page.png), and [diff](qa/evidence/visual-diff.png) PNGs | Viewport and full-page `screenshot`, targeted input with `fill`, and `visual compare` producing before, after, and diff PNGs. The E2E suites also verify JPG/JPEG, single-capture PDF, macOS image clipboard output, MOV, and WebM artifacts. |
| [Diagnostics](qa/evidence/04-diagnostics.mp4) | [Probe results](qa/evidence/media-probe.json) | Page reload plus `console list`, `network list`, `cookies list`, `storage list`, and `qa report` with values kept redacted |
| [Network emulation and mocking](qa/evidence/05-network-emulation-mocking.mp4) | [Probe results](qa/evidence/media-probe.json) | `network emulate`, fixture reload, `network mock set`, mocked reload, `network mock clear`, and restored reload |
| [Safe navigation and input](qa/evidence/06-safe-navigation-input.mp4) | [Probe results](qa/evidence/media-probe.json) | `fill`, `press`, blocked external, non-web, credential-bearing, and installer links, blocked scripted navigation, and an allowed Continue action |
| [Flows and reports](qa/evidence/07-flows-reports.mp4) | [Probe results](qa/evidence/media-probe.json), [recorded flow](qa/evidence/dashboard-flow.json), and [QA report](qa/evidence/pr-report.json) | `flow start`, recorded visit and click, `flow stop`, `flow run`, and `report create` |
| [Performance and animations](qa/evidence/08-performance-animations.mp4) | [Probe results](qa/evidence/media-probe.json) | `performance get`, `animations list`, tours, scrolling, and checks across both fixture pages |
| [Recording and artifact lifecycle](qa/evidence/09-recording-artifact-lifecycle.mp4) | [Probe results](qa/evidence/media-probe.json), [viewport](qa/evidence/lifecycle-viewport.png), and [full-page](qa/evidence/lifecycle-full-page.png) screenshots | `record start/status/stop`, rejection of a second recording, screenshots, `artifacts list`, and `capture-info` |
| [MCP stdio invocation](qa/evidence/10-mcp-stdio-invocation.mp4) | [Probe results](qa/evidence/media-probe.json) | Real JSON-RPC requests piped to `headless-mcp`: `initialize`, `tools/list`, and two `tools/call` requests over stdio |
| [Progressive context pruning](qa/evidence/11-progressive-context-pruning.mp4) | [Context measurements](qa/evidence/context-pruning-results.json) and [probe results](qa/evidence/media-probe.json) | A 120-section document inspected with `full`, task-ranked `summary` and `outline`, then scoped `text` and `actions` through a stable `@rN` reference and explicit budgets |

The eight browser-visible files use `headless --session qa record start --fps 5` and `record stop`. Each recording contains navigation, scrolling, input, tours, or reloads with waits between state changes. The Docker harness records terminal scenarios with FFmpeg `x11grab` on `DISPLAY=:99` against an xterm running the real commands. The committed progressive-pruning proof uses an actual asciicast of `pnpm test:runtime`, rendered to MP4, because the development host does not permit Chromium's namespace sandbox; it does not disable or bypass that sandbox.

## Command transcript

These are the feature commands, with the fixed fixture URL and artifact names used by the harness. Each browser block is enclosed by `record start` and `record stop`. The harness adds 2 to 4 second waits between visible state changes.

```sh
# Runtime selection and Snap rejection
headless runtime
HEADLESS_CHROMIUM_EXECUTABLE=/snap/bin/chromium headless runtime
headless capabilities

# Startup, session, navigation, and reload
headless start
headless session create qa
headless session list
headless --session qa record start --fps 5 --output 02-startup-session-navigation.mp4
headless --session qa tour --full-page --pace 1000
headless --session qa visit http://127.0.0.1:41739/next
headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000
headless --session qa reload
headless --session qa back
headless --session qa reload
headless --session qa record stop

# Screenshots and visual comparison
headless --session qa record start --fps 5 --output 03-screenshots-visual-comparison.mp4
headless --session qa inspect --context actions --task "click Continue"
headless --session qa screenshot --output visual-before.png
headless --session qa screenshot --format jpg --output visual-before.jpg
headless --session qa screenshot --format pdf --full-page --output visual-full-page.pdf
headless --session qa scroll bottom
headless --session qa screenshot --full-page --output visual-full-page.png
headless --session qa screenshot --every-viewport --format jpg --output visual-scroll
headless --session qa screenshot --by-section --output visual-sections
headless --session qa scroll top
headless --session qa fill @e1 'QA reviewer'
headless --session qa screenshot --output visual-after.png
headless --session qa visual compare visual-before.png visual-after.png --output visual-diff.png
headless --session qa tour --full-page --pace 1000
headless --session qa record stop

# Diagnostics
headless --session qa record start --fps 5 --output 04-diagnostics.mp4
headless --session qa reload
headless --session qa console list --level error
headless --session qa network list
headless --session qa cookies list
headless --session qa storage list
headless --session qa qa report
headless --session qa record stop

# Network emulation and mocking
headless --session qa record start --fps 5 --output 05-network-emulation-mocking.mp4
headless --session qa network emulate --latency 25 --download-kbps 1000 --upload-kbps 500
headless --session qa reload
headless --session qa network mock set http://127.0.0.1:41739/api/diagnostic --body '{"mocked":true}' --status 201 --content-type application/json
headless --session qa reload
headless --session qa network mock clear
headless --session qa reload
headless --session qa record stop

# Safe navigation and input
headless --session qa record start --fps 5 --output 06-safe-navigation-input.mp4
headless --session qa inspect --context actions --task "click Continue"
headless --session qa fill @e1 'QA reviewer'
headless --session qa press Tab
headless --session qa press Escape
headless --session qa click --role link --name 'External application'
headless --session qa click --role link --name 'Non-web browser URL'
headless --session qa click --role link --name 'Credential-bearing URL'
headless --session qa click --role link --name 'Suspicious installer'
headless --session qa click --role button --name 'Scripted non-web navigation'
headless --session qa click --role button --name Continue
headless --session qa wait --url /next --text 'Designer details' --settled --timeout 10000
headless --session qa record stop

# Flows and reports
headless --session qa record start --fps 5 --output 07-flows-reports.mp4
headless --session qa flow start
headless --session qa visit http://127.0.0.1:41739/designers/dashboard
headless --session qa click --role button --name Continue
headless --session qa flow stop --output dashboard-flow.json
headless --session qa flow run dashboard-flow.json
headless --session qa report create --output pr-report.json
headless --session qa record stop

# Performance and animation inspection
headless --session qa record start --fps 5 --output 08-performance-animations.mp4
headless --session qa performance get
headless --session qa animations list
headless --session qa visit http://127.0.0.1:41739/next
headless --session qa performance get
headless --session qa back
headless --session qa animations list
headless --session qa record stop

# Recording and artifact lifecycle
headless --session qa record start --fps 5 --output 09-recording-artifact-lifecycle.mp4
headless --session qa record status
headless --session qa record start
headless --session qa screenshot --output lifecycle-viewport.png
headless artifacts list
headless --session qa capture-info
headless --session qa screenshot --full-page --output lifecycle-full-page.png
headless --session qa record stop
headless --session qa record status

# MCP stdio requests
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["status"]}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["--session","qa","inspect","--interactive","--text"]}}}' \
  | headless-mcp

# Progressive context pruning on the 120-section fixture
headless --session qa visit http://127.0.0.1:41739/large-document
headless --session qa inspect --context full
headless --session qa inspect --context summary \
  --task 'Linux service-account authentication' --limit 8 --budget 700
headless --session qa inspect --context outline \
  --task 'Linux service-account authentication' --limit 8 --budget 900
headless --session qa inspect --context text --within @rN \
  --task 'Ubuntu service account' --limit 4 --budget 700
headless --session qa inspect --context actions --within @rN \
  --task 'copy authentication command' --limit 5 --budget 700
```

Before every browser recording, the harness visits `http://127.0.0.1:41739/designers/dashboard` and waits for the page to settle. Scroll, tour, and wait calls used for visible pacing are kept in the script next to each feature command.

## Artifacts and checks

The eleven recordings and all generated artifacts from the successful run are committed in [`docs/qa/evidence/`](qa/evidence/). The set includes screenshot and visual-diff PNGs, the recorded flow, the QA report, [context-pruning measurements](qa/evidence/context-pruning-results.json), [media probe results](qa/evidence/media-probe.json), [test results](qa/evidence/test-results.json), and [SHA-256 checksums](qa/evidence/SHA256SUMS).

For every MP4, the harness runs these checks:

```sh
test -s "$VIDEO"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name \
  -of default=nokey=1:noprint_wrappers=1 "$VIDEO"
ffprobe -v error -show_entries format=duration \
  -of default=nokey=1:noprint_wrappers=1 "$VIDEO"
```

The run fails unless all eleven files are non-empty, contain a video stream, and last at least 10 seconds. It also scans video, JSON, and image artifacts for the fixture's sensitive test strings. It then checksums every generated evidence file and verifies `SHA256SUMS` with `sha256sum -c`.

## Test results

Successful completion prints `All QA evidence checks passed.` and writes `"result": "pass"` to both `media-probe.json` and `test-results.json`. `media-probe.json` records the measured duration and video codec for each recording. Any CLI assertion, fixture startup failure, recording failure, probe failure, checksum mismatch, or sensitive test string stops the run with a nonzero status.

The recorded run completed successfully on the bundled `/usr/lib/chromium/chromium` runtime. All checksums in `SHA256SUMS` were verified.

### Measured recording durations

| Recording | Duration (seconds) |
| --- | ---: |
| [Runtime selection and Snap rejection](qa/evidence/01-runtime-selection-snap-rejection.mp4) | 18.000000 |
| [Startup, session, and navigation](qa/evidence/02-startup-session-navigation.mp4) | 11.600000 |
| [Screenshots and visual comparison](qa/evidence/03-screenshots-visual-comparison.mp4) | 11.400000 |
| [Diagnostics](qa/evidence/04-diagnostics.mp4) | 11.800000 |
| [Network emulation and mocking](qa/evidence/05-network-emulation-mocking.mp4) | 11.800000 |
| [Safe navigation and input](qa/evidence/06-safe-navigation-input.mp4) | 11.600000 |
| [Flows and reports](qa/evidence/07-flows-reports.mp4) | 10.600000 |
| [Performance and animations](qa/evidence/08-performance-animations.mp4) | 11.400000 |
| [Recording and artifact lifecycle](qa/evidence/09-recording-artifact-lifecycle.mp4) | 13.200000 |
| [MCP stdio invocation](qa/evidence/10-mcp-stdio-invocation.mp4) | 18.000000 |
| [Progressive context pruning](qa/evidence/11-progressive-context-pruning.mp4) | 13.040000 |

Static checks for this change:

```sh
bash -n apps/headless/Tests/qa-videos.sh
pnpm test:runtime
git diff --check
```

These checks pass on the current branch. The harness treats a partial run as a failure and writes passing result files only after all recordings and probes succeed.

## Limitations

- The first run builds Swift release binaries and installs the derived image packages, so it can take several minutes.
- Terminal evidence requires working Xvfb, xterm, FFmpeg `x11grab`, and `DISPLAY=:99` inside the container. The harness fails clearly if the display is unavailable and never substitutes fabricated media.
- Recordings are silent because the fixture flows do not exercise audio.
- The default output remains a timestamped directory under `build/qa-evidence/`; the evidence for this change is committed under `docs/qa/evidence/`.
