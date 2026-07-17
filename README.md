# chromeless

pnpm workspace. Native macOS browser shell lives in `apps/chromeless`.

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
