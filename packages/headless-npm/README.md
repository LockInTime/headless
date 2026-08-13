# `@lockintime/headless`

Verified npm launcher for the [Headless agent browser](https://github.com/LockInTime/headless).

```sh
npx @lockintime/headless help
npx -p @lockintime/headless headless-mcp
```

The launcher downloads the release matching its own package version from the
official GitHub repository, verifies the exact asset against `SHA256SUMS`,
validates the archive shape and embedded product version, and caches it in a
private per-user directory. It supports macOS 13+ on Apple Silicon and Intel,
plus Linux x86_64 and arm64. Windows users should use the published GHCR image.

Set `HEADLESS_NPM_CACHE` to an absolute directory to move the verified cache.
The release download origin is fixed and cannot be overridden.
