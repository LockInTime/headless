# Command reference

Every command the `headless` CLI accepts. Usage lines below are kept verbatim
from `agentHelp` in `Sources/HeadlessProtocol/CLI.swift`, and a protocol-suite
test (`docsCommandReferenceMatchesHelp`) fails when they drift apart.

All commands talk to one persistent host over a private per-user Unix socket.
There is no TCP listener and no way to execute arbitrary JavaScript.
Page-derived strings are always marked as untrusted content, and every
response that can be large reports what it left out (`truncated`, `omitted`,
`contextStats`).

Global options:

```sh
headless --session NAME <command>   # target a named session
headless <command> -- --value       # stop option parsing; literal values
```

## Host lifecycle

```sh
version | --version
start [--background|--foreground] | status | stop | runtime
config get startup-presentation
config set startup-presentation background|foreground
session create [NAME] | session list | session close NAME
capabilities
```

- `start` launches the host if it is not already running. `status` and `stop`
  control it afterwards. `runtime` reports which engine is active and where it
  came from.
- `config startup-presentation` is macOS only; other engines reject it.
- Sessions are windows (macOS) or tabs (Linux) sharing **one browser profile**.
  Cookies and storage are shared across sessions — see P1.md for why this is
  not an isolation boundary.

## Navigation and interaction

```sh
visit URL
inspect [--context summary|outline|text|actions|full] [--task TEXT]
        [--within @rN] [--limit N] [--budget TOKENS] [--depth N] [--text]
click REF | click --role ROLE [--name NAME]
fill REF TEXT | fill REF -- TEXT_WITH_LITERAL_FLAGS | press KEY
scroll [up|down|top|bottom] [--amount PX]
back | reload
wait [--settled] [--url PATTERN] [--text TEXT] [--timeout MS]
tour [--full-page] [--pace PX_PER_SECOND]
```

```sh
visit URL
back | reload
```

- `visit` accepts HTTP/HTTPS only. Bare hostnames normalize to HTTP
  (`localhost:3000` → `http://localhost:3000`). URLs carrying credentials are
  rejected. Downloads and unsafe schemes never navigate.
- `inspect` is how an agent sees the page. Element references (`@eN`) belong to
  the most recent inspection and are reissued on every inspect; region
  references (`@rN`) stay resolvable so you can outline first and scope later.
  See "Reference lifetime" in P1.md for the full contract.
- `click`, `fill`, and `press` accept either a reference or a semantic target
  (`--role`/`--name`). On Linux these dispatch trusted CDP input events;
  WebKit uses synthetic input, and capabilities declare the difference.
- `fill REF -- value` keeps leading dashes in the value. Flow recordings never
  record fill values.
- `wait --timeout` and the tour duration are bounded; unbounded waits are
  rejected at parse time.

## Capture and evidence

```sh
capture-info
screenshot [REF | --role ROLE --name NAME | --full-page] [--format png|jpg|jpeg] [--output FILE] [--clipboard]
screenshot --full-page --format pdf [--output FILE.pdf]
screenshot --every-viewport|--by-section [--format png|jpg|jpeg] [--output PREFIX]
artifacts list
record start [--fps N] [--format mp4|mov|webm|gif] [--quality fast|balanced|high] [--output FILE]
record status | record stop [--output FILE]
qa report | qa clear
report create [--output REPORT.json]
```

- Screenshots and recordings become private artifacts in the per-user store,
  created `O_EXCL` with `0600`. They never overwrite and never leave it unless
  you copy them.
- `--clipboard` capture is macOS only. Linux rejects clipboard capture because
  VM clipboards are not a reliable boundary.
- PDF screenshots and element-scoped capture follow the engine matrix reported
  by `capabilities`.
- The recorder captures browser pixels through ffmpeg only: no OS chrome, no
  microphone, no system audio.

## Diagnostics

```sh
console list [--level LEVEL] [--limit N]
network list [--failed] [--status CODE] [--limit N]
network get REQUEST_ID
network emulate [--offline] [--latency MS] [--download-kbps N] [--upload-kbps N]
network mock set URL --body BODY [--status CODE] [--content-type MIME]
network mock clear
styles get REF | styles get --role ROLE [--name NAME] [--property CSS_PROPERTY]
cookies list [--values]
storage list [--scope local|session|all] [--values]
visual compare BEFORE.png AFTER.png [--output DIFF.png]
performance get | animations list
flow start | flow stop [--output FLOW.json] | flow run FLOW.json
```

- `network emulate` and `network mock` are Chromium-engine features. WebKit
  returns `UNSUPPORTED_CAPABILITY` instead of approximating them.
- `cookies list --values` and `storage list --values` are double-gated: the
  flag plus `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1` on the host. Without both
  you get names and metadata, never values.
- `visual compare` accepts only existing private PNG artifacts, not filesystem
  paths, and writes its difference image back into the artifact store.
- Flows replay recorded commands but skip every `fill` value by design; rerun
  fills explicitly when you replay.

## Where to go next

- Phase contracts: [P0.md](P0.md), [P1.md](P1.md), [P2.md](P2.md)
- Engine differences matrix: `headless capabilities`
- Benchmark method: [BENCHMARK.md](BENCHMARK.md)
