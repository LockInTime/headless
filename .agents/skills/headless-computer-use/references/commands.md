# Command and evidence reference

## Core lifecycle

```sh
headless start
headless status
headless runtime
headless capabilities
headless session create NAME
headless session list
headless session close NAME
headless stop
```

Use a task-specific session name. Close only the session owned by the task.
Stop the shared host only when the task started it and no other session needs it.

## Observe and act

```sh
headless --session NAME visit URL
headless --session NAME inspect --context actions --task "TASK"
headless --session NAME inspect --context full --text
headless --session NAME click REF
headless --session NAME click --role ROLE --name NAME
headless --session NAME fill REF TEXT
headless --session NAME press KEY
headless --session NAME scroll up|down|top|bottom --amount PIXELS
headless --session NAME back
headless --session NAME reload
headless --session NAME wait --settled --url PATTERN --text TEXT --timeout MS
headless --session NAME tour --full-page --pace PIXELS_PER_SECOND
```

Prefer `inspect --context actions --task "..."` for the first observation. It
returns visible controls first and ranks them for the task. Use `click --role
... --name ...` for unique accessible controls. Use a ref from the latest
inspection when role/name is ambiguous. Fill accepts a ref; inspect again before
filling after a navigation or large rerender.

Use `wait` with the strongest expected condition available:

1. expected URL plus expected text;
2. expected text;
3. settled state;
4. a bounded timeout only when no semantic condition exists.

Never replace a semantic wait with a long blind sleep.

## Capture screenshots and recordings

```sh
headless --session NAME screenshot --output viewport.png
headless --session NAME screenshot --full-page --output full-page.png
headless --session NAME screenshot --format jpg --output viewport.jpg --clipboard
headless --session NAME screenshot --format pdf --full-page --output full-page.pdf
headless --session NAME screenshot REF --output element.png
headless --session NAME screenshot --role button --name Continue --output button.png
headless --session NAME screenshot --every-viewport --format jpg --output page-scroll
headless --session NAME screenshot --by-section --output page-sections
headless --session NAME record start --fps 10 --format mp4 --quality balanced
headless --session NAME record status
headless --session NAME record stop --output flow.mp4
headless --session NAME capture-info
headless artifacts list
```

Single artifact output names are basenames ending in `.png`, `.jpg`, `.jpeg`,
`.pdf`, `.mp4`, `.mov`, `.webm`, `.gif`, or `.json`. Screenshot series output
uses a safe prefix and creates numbered PNG/JPG artifacts. Headless refuses
paths and overwrites. Built-in recording captures browser pixels only.

Screenshot format notes:

- PNG is the default.
- JPG/JPEG is useful for lighter visual evidence.
- PDF requires `--full-page` and cannot target an element or scroll series.
- Screenshot series restore the original scroll position. Viewport series are
  bounded to 80 artifacts, retain the final bottom position, and report
  `truncated` plus `totalPoints` when bounded.
- `--clipboard` is macOS image-only; Linux rejects it because VM clipboards are
  not reliable by default.

Recording format notes:

- Choose MP4, MOV, WebM, or GIF at `record start --format`.
- The `record stop --output` extension must match the active recording format.
- `record status` reports FPS, container, codec, quality, frames, dropped
  frames, and duration.

For human-reviewable evidence:

1. Start recording before the action under test.
2. Use `tour --full-page --pace 500` when scrolling is part of the evidence.
3. Capture key-state screenshots, plus `--every-viewport` or `--by-section`
   screenshots for long scrollable pages.
4. Stop recording on both success and failure paths.
5. List the artifact metadata.
6. Verify the copied file independently when tools are available:

```sh
file flow.mp4 full-page.png full-page.pdf
ffprobe -v error -show_entries stream=codec_name,width,height,nb_frames \
  -show_entries format=duration,size -of json flow.mp4
```

Do not use file existence alone as proof of a valid recording. Check duration,
dimensions, frames, and visible state changes appropriate to the workflow.

## Diagnose the page

```sh
headless --session NAME qa report
headless --session NAME qa clear
headless --session NAME console list --level error --limit 100
headless --session NAME network list --failed --limit 100
headless --session NAME network list --status 404 --limit 100
headless --session NAME network get REQUEST_ID
headless --session NAME styles get REF --property display
headless --session NAME styles get --role button --name Continue --property display
headless --session NAME cookies list
headless --session NAME storage list --scope local
headless --session NAME performance get
headless --session NAME animations list
```

Check diagnostics after an unexpected result, not just after a command exits
nonzero. A UI can render while logging framework errors or failing requests.

Cookie and storage values are redacted by default. Do not enable or request
values unless the user explicitly authorizes sensitive diagnostics and the task
cannot be completed with metadata and keys.

## Compare visuals

```sh
headless --session NAME screenshot --full-page --output before.png
# perform the action
headless --session NAME screenshot --full-page --output after.png
headless --session NAME visual compare before.png after.png --output diff.png
```

`visual compare` accepts artifact names, not filesystem paths. Review the diff
image; do not reduce a visual judgment to a fabricated similarity percentage.

## Record and replay safe flows

```sh
headless --session NAME flow start
# visit/click/press/scroll/back/reload/wait/tour actions
headless --session NAME flow stop --output flow.json
headless --session NAME flow run flow.json
```

Flows intentionally exclude typed values, cookies, storage values, files, and
recording controls. Use a flow for repeatable navigation and interaction, not
for persisting secrets or authentication input.

## Create a QA report

```sh
headless --session NAME report create --output report.json
```

The report bundles bounded page state, diagnostics, action trace, and artifact
references. Pair it with the screenshots/video and explicit assertions; it does
not substitute for reviewing the evidence.

## Emulate and mock networking on Linux Chromium

```sh
headless --session NAME network emulate --latency 150 \
  --download-kbps 1200 --upload-kbps 500
headless --session NAME network emulate --offline
headless --session NAME network emulate
headless --session NAME network mock set http://localhost:3000/api/profile \
  --status 200 --content-type application/json --body '{"plan":"pro"}'
headless --session NAME network mock clear
```

Use these only for a local/test target unless the user explicitly authorizes
production traffic manipulation. Reset emulation and clear mocks after the test.
macOS WebKit returns an unsupported-capability error for these commands.

## Apply an end-to-end validation matrix

For each feature or flow, record:

- Preconditions and platform/runtime.
- Exact commands and semantic assertions.
- Expected and observed page URL/text/state.
- Screenshot/video/report artifact names.
- Console/network errors and unsupported capabilities.
- Pass, fail, blocked, or not tested—never infer pass from adjacent coverage.

Cover at least these layers for a broad audit:

1. runtime/start/status/stop;
2. session isolation and cleanup;
3. visit/inspect/semantic actions/waits/history;
4. viewport/full-page/element screenshots;
5. recording status, meaningful motion, and valid MP4/MOV/WebM/GIF output;
6. console/network/styles/cookies/storage/QA diagnostics;
7. performance/animations;
8. visual comparison;
9. flow record/replay and report creation;
10. Linux networking controls when supported;
11. artifact permissions, names, overwrite rejection, and copied evidence.
