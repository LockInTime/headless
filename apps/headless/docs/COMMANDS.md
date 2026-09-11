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
profile clear
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
  Cookies and local storage are shared across sessions and survive host and
  machine restarts. `profile clear` closes every session and permanently
  removes normal-profile cookies, storage, caches, and permissions.

## Credential vault

```sh
credentials list [--origin URL]
credentials add --origin URL --alias NAME --interactive
credentials rename --origin URL --alias OLD --to NEW
credentials remove --origin URL --alias NAME
```

Credential commands are local-only and never enter the browser protocol or MCP.
`credentials add` reads the username and password from `/dev/tty`, hides and
confirms the password, rejects redirected standard input, and restores terminal
echo after success, failure, or a handled signal. Passwords are never accepted
in arguments or environment variables and never appear in command output.

Origins are exact HTTPS origins with lowercase hosts and normalized default
ports. Paths, queries, fragments, embedded credentials, and public HTTP origins
are rejected. HTTP is accepted only for `localhost`, `127.0.0.1`, and `::1`
development origins. Aliases are 1-64 ASCII letters, numbers, periods,
underscores, or hyphens and are case-insensitively unique per origin.

macOS stores passwords in the encrypted default user Keychain with an empty
trusted-app list and passphrase protection on the decryption ACL. A fresh
broker-owned native user-presence gate is added to retrieval by #157. The
vault uses no shared access group. Local/ad-hoc builds are reported as
`local-unnotarized`; rebuilds may make macOS ask again. This deliberately uses
the file-based default Keychain because Apple's biometric data-protection Keychain requires a
provisioning-profile-authorized app identity. The file-based API is deprecated,
so a future Developer ID release must migrate the same record semantics rather
than silently changing them. Linux uses the system
Secret Service through `/usr/bin/secret-tool` and the current user's validated
`/run/user/UID/bus` socket. Caller-supplied D-Bus addresses are ignored. Vault
commands are time-bounded; missing, locked, denied, timed-out, or unknown
backend failures fail closed without creating a plaintext store. Listing
reads only a private `0600` nonsecret alias index inside a `0700` directory.
Corrupt, oversized, symlinked, foreign-owned, or permissive metadata fails
closed instead of being replaced.

Secrets are not exported or backed up by Headless; the OS vault owns its own
backup and recovery behavior. Index writes are atomic. A durable transaction
journal rolls back interrupted additions and completes interrupted deletions
on the next vault command. Renames atomically update only the nonsecret index.
Unknown future index schemas require an explicit migration. Normal-vault
aliases are unavailable to private contexts. Saved credential use and login
challenges are implemented separately by issue #157; until then these commands
manage records but do not autofill them.

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
