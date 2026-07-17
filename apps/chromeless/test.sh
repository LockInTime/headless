#!/bin/zsh
set -euo pipefail
cd "${0:a:h}"

for tool in swift swiftc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "chromeless tests: missing $tool. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 69
  fi
done

SDK_ARGS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Some Command Line Tools releases briefly ship a compiler newer than the
  # default SDK symlink. Choose the newest SDK the compiler can actually read.
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(NOn); do
    if swiftc -module-cache-path build/module-cache -sdk "$sdk" \
        -target "$(uname -m)-apple-macos13.0" -typecheck \
        Sources/ChromelessProtocol/Protocol.swift >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      SDK_ARGS=(--sdk "$sdk")
      break
    fi
  done
  if [[ -z "${SDKROOT:-}" ]]; then
    echo "chromeless tests: no compatible macOS SDK was found. Update Xcode Command Line Tools." >&2
    exit 69
  fi
  export CLANG_MODULE_CACHE_PATH="${PWD}/build/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${PWD}/build/swiftpm-module-cache"
fi

TEST_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/chromeless-tests.XXXXXX")"
trap 'rm -rf "$TEST_SCRATCH"' EXIT
BIN_PATH="$(swift build "${SDK_ARGS[@]}" --scratch-path "$TEST_SCRATCH" --show-bin-path)"
swift build "${SDK_ARGS[@]}" --product chromeless-protocol-tests --scratch-path "$TEST_SCRATCH"
"$BIN_PATH/chromeless-protocol-tests"
