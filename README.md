# chromeless

pnpm workspace. Native macOS browser shell lives in `apps/chromeless`.

## Supported runtime

This repository supports only the native macOS app in `apps/chromeless`, which
uses WKWebView. It does not contain a Chromium runtime, an MCP or browser-control
layer, a Docker setup, a Linux launcher, or a P2 test suite. Linux Chromium
control and P2 flows therefore cannot be run or validated from this repository.

Ubuntu Snap Chromium has been reported to load the first local page while its
control connection may freeze during later navigation or reload. That behavior
has not been reproduced or verified here because the affected Chromium control
stack is not part of this repository.

A Docker environment with a bundled Linux Chromium runtime has separately been
reported to complete the full P2 flow. That result is also external and has not
been verified here; this repository does not provide that image, runtime, or
test flow.

The Linux control-layer fix belongs in the repository that owns that layer. It
should use a bundled, versioned Linux Chromium runtime instead of relying on
Ubuntu Snap Chromium, and validate navigation and reload behavior there.

## Setup

```sh
pnpm install
```

## Chromeless app

```sh
pnpm build   # → apps/chromeless/Chromeless.app
pnpm start   # build + open
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Layout

```
apps/chromeless   # Swift WKWebView app
packages/         # shared packages (empty for now)
```
