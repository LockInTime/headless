# Setup and launch

## Choose a command path

Use one command path for an entire task. Do not mix native and container
sessions because they have different Unix sockets, profiles, and artifact
stores.

### Installed native CLI

```sh
command -v headless
headless runtime
headless capabilities
headless start
```

On Linux, `runtime` must select an absolute executable native Chromium binary.
Snap Chromium is rejected. FFmpeg is required for built-in MP4 recording.

### Repository build on macOS

```sh
./apps/headless/build.sh
./apps/headless/Headless.app/Contents/Resources/bin/headless runtime
./apps/headless/Headless.app/Contents/Resources/bin/headless start
```

`pnpm start` builds and opens the visible WKWebView application. Use the binary
path above when an agent needs predictable CLI invocation.

### Repository build on native Linux

```sh
./apps/headless/build-linux.sh
./apps/headless/build/linux/install-linux.sh --prefix /absolute/private/prefix
/absolute/private/prefix/bin/headless runtime
/absolute/private/prefix/bin/headless start
```

Use a native distribution Chromium package. Set
`HEADLESS_CHROMIUM_EXECUTABLE` only to an absolute executable regular file.
Never add `--no-sandbox` or run the Linux host as root.

## Use the supported Linux Docker sandbox

Use the bundled wrapper from the repository root:

```sh
SANDBOX=.agents/skills/headless-computer-use/scripts/headless-sandbox.sh
$SANDBOX doctor
$SANDBOX start
$SANDBOX exec capabilities
$SANDBOX exec session create agent-qa
$SANDBOX exec --session agent-qa visit https://example.com
$SANDBOX exec --session agent-qa inspect --context actions --task "find primary action"
```

The wrapper builds the `production` target, starts one persistent non-root
container, and then invokes the normal CLI with `exec`. It adds
`host.docker.internal` for a development server running on the Docker host:

```sh
$SANDBOX exec --session agent-qa visit http://host.docker.internal:3000
```

Some Linux firewalls deny Docker bridge traffic back to host services. For a
trusted local development server only, opt into host networking and visit
`localhost` directly. Use a distinct container name or remove the stopped
bridge container first; the wrapper rejects a network mismatch instead of
silently reusing the wrong container.

```sh
HEADLESS_SKILL_NETWORK=host \
HEADLESS_SKILL_CONTAINER=headless-local-app \
  $SANDBOX start
HEADLESS_SKILL_NETWORK=host \
HEADLESS_SKILL_CONTAINER=headless-local-app \
  $SANDBOX exec --session agent-qa visit http://localhost:3000
```

Host networking lets the browser reach services bound to the host network.
Keep bridge mode for untrusted or external browsing.

The test container needs `SYS_ADMIN` only so nested Chromium namespaces can
initialize. The browser host remains non-root and never uses `--no-sandbox`.

If Docker permission is denied but the current user is already in the `docker`
group, start a new login shell. As a temporary local fallback, wrap one complete
wrapper invocation with the host's approved group-launch mechanism; do not add
world-writable Docker sockets.

Copy private artifacts before removing the container:

```sh
$SANDBOX exec artifacts list
$SANDBOX copy flow.mp4 ./flow.mp4
$SANDBOX stop
```

`stop` preserves the container and its artifacts. `remove` deletes the named
skill container and all artifacts still inside it; use it only for an explicit
reset after evidence has been copied.

Override the isolated resources only to avoid a known naming conflict:

```sh
HEADLESS_SKILL_IMAGE=my-headless-image \
HEADLESS_SKILL_CONTAINER=my-headless-agent \
  $SANDBOX start
```

## Use a visible browser

macOS is visible by default. Linux is headless when no `DISPLAY` is present.
For a visible native Linux browser, run the host in an existing logged-in
desktop session with `HEADLESS_HEADLESS=0` and a valid `DISPLAY`. Do not expose
a remote-debugging port to make it visible.

## Configure the stdio MCP adapter

Start the browser host first. Configure an MCP client to launch the native
`headless-mcp` executable over stdio:

```toml
[mcp_servers.headless]
command = "/absolute/path/to/headless-mcp"
```

For the Docker sandbox, configure the wrapper after `$SANDBOX start`:

```toml
[mcp_servers.headless]
command = "/absolute/path/to/.agents/skills/headless-computer-use/scripts/headless-sandbox.sh"
args = ["mcp"]
```

The server exposes one `headless` tool. Supply the normal CLI arguments without
the executable name:

```json
{"argv":["--session","agent-qa","inspect","--context","actions","--task","find primary action"]}
```

Keep MCP on stdio locally or invoke it through SSH. Do not expose the Unix socket,
Chromium debugging pipe, or an unauthenticated TCP bridge.

## Troubleshoot launch failures

```sh
headless runtime
headless status
headless capabilities
```

For Docker:

```sh
$SANDBOX doctor
$SANDBOX status
docker logs headless-computer-use
```

Interpret common failures as follows:

- `UNSUPPORTED_BROWSER_RUNTIME`: install/select native non-Snap Chromium.
- `RECORDER_UNAVAILABLE`: install FFmpeg or use the Docker runtime.
- `Headless host is not running`: run `start` in the same native/container
  environment as the CLI command.
- `UNSUPPORTED_CAPABILITY`: do not pretend partial support; use a supported
  platform or record the limitation.
- Docker sandbox startup failure: check Docker access, free disk, and the named
  container state before rebuilding.
