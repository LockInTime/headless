import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { after, before, test } from "node:test";
import {
  checksumFromManifest,
  defaultCacheRoot,
  ensureInstalled,
  InstallError,
  platformRelease,
  validateArchiveEntries,
} from "../lib/installer.mjs";

const root = mkdtempSync(join(tmpdir(), "headless-npm-test."));
const fixture = join(root, "fixture");
const version = "9.8.7";
const asset = `headless-${version}-linux-amd64.tar.gz`;
const archive = join(root, asset);
let server;
let baseURL;
let requestCount = 0;
let servedManifest;

before(async () => {
  mkdirSync(join(fixture, "Headless_HeadlessProtocol.resources"), { recursive: true });
  for (const executable of ["headless", "headless-host", "headless-mcp", "install-linux.sh"]) {
    const body = executable === "headless"
      ? `#!/bin/sh\nif [ "$1" = --version ]; then echo 'headless ${version}'; else echo wrapper-ok; fi\n`
      : "#!/bin/sh\nexit 0\n";
    writeFileSync(join(fixture, executable), body, { mode: 0o755 });
    chmodSync(join(fixture, executable), 0o755);
  }
  writeFileSync(join(fixture, "Headless_HeadlessProtocol.resources", "AgentRuntime.js"), "// fixture\n");
  const packed = spawnSync("/usr/bin/tar", [
    "-czf",
    archive,
    "-C",
    fixture,
    "headless",
    "headless-host",
    "headless-mcp",
    "install-linux.sh",
    "Headless_HeadlessProtocol.resources",
  ], { encoding: "utf8" });
  assert.equal(packed.status, 0, packed.stderr);
  const archiveBytes = readFileSync(archive);
  const checksum = createHash("sha256").update(archiveBytes).digest("hex");
  servedManifest = `${checksum}  ${asset}\n`;
  server = createServer((request, response) => {
    requestCount += 1;
    if (request.url.endsWith("/SHA256SUMS")) {
      response.end(servedManifest);
    } else if (request.url.endsWith(`/${asset}`)) {
      response.end(archiveBytes);
    } else {
      response.statusCode = 404;
      response.end();
    }
  });
  await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  baseURL = `http://127.0.0.1:${server.address().port}/v${version}`;
});

after(async () => {
  await new Promise((resolvePromise) => server.close(resolvePromise));
  rmSync(root, { recursive: true, force: true });
});

test("maps only supported release platforms", () => {
  assert.equal(platformRelease(version, "linux", "x64").asset, asset);
  assert.equal(platformRelease(version, "linux", "arm64").key, "linux-arm64");
  assert.equal(platformRelease(version, "darwin", "arm64").kind, "zip");
  assert.throws(() => platformRelease(version, "win32", "x64"), InstallError);
  assert.throws(() => platformRelease("../bad", "linux", "x64"), InstallError);
});

test("requires an absolute cache override", () => {
  assert.throws(
    () => defaultCacheRoot("linux", { HEADLESS_NPM_CACHE: "relative" }),
    /absolute path/,
  );
});

test("parses one exact manifest entry", () => {
  const digest = "a".repeat(64);
  assert.equal(checksumFromManifest(`${digest}  ${asset}\n`, asset), digest);
  assert.throws(() => checksumFromManifest("", asset), /exactly one/);
  assert.throws(
    () => checksumFromManifest(`${digest}  ${asset}\n${digest}  ${asset}\n`, asset),
    /exactly one/,
  );
});

test("rejects archive traversal and missing runtime files", () => {
  assert.throws(() => validateArchiveEntries("../escape\n", "tar.gz"), /unsafe path/);
  assert.throws(() => validateArchiveEntries("safe//file\n", "tar.gz"), /unsafe path/);
  assert.throws(() => validateArchiveEntries("safe/file\nsafe/file/\n", "tar.gz"), /duplicate path/);
  assert.throws(() => validateArchiveEntries("headless\n", "tar.gz"), /missing headless-host/);
  assert.throws(
    () => validateArchiveEntries("Headless.app/Contents/MacOS/Headless\noutside\n", "zip"),
    /missing Headless.app\/Contents\/Resources\/bin\/headless/,
  );
});

test("rejects a release whose checksum does not match", async () => {
  const validManifest = servedManifest;
  servedManifest = `${"0".repeat(64)}  ${asset}\n`;
  try {
    await assert.rejects(
      ensureInstalled({
        version,
        platform: "linux",
        architecture: "x64",
        cacheRoot: join(root, "bad-checksum-cache"),
        releaseBaseURL: baseURL,
        allowedHosts: new Set(["127.0.0.1"]),
        allowHTTP: true,
        allowCustomPort: true,
      }),
      /checksum mismatch/,
    );
  } finally {
    servedManifest = validManifest;
  }
});

test("downloads, verifies, installs, and reuses the cached release", async () => {
  const cacheRoot = join(root, "cache");
  const options = {
    version,
    platform: "linux",
    architecture: "x64",
    cacheRoot,
    releaseBaseURL: baseURL,
    allowedHosts: new Set(["127.0.0.1"]),
    allowHTTP: true,
    allowCustomPort: true,
  };
  const first = await ensureInstalled(options);
  assert.equal(first.release.asset, asset);
  const command = spawnSync(join(first.directory, first.release.executable), [], { encoding: "utf8" });
  assert.equal(command.status, 0);
  assert.equal(command.stdout.trim(), "wrapper-ok");
  const afterFirst = requestCount;
  const second = await ensureInstalled(options);
  assert.equal(second.directory, first.directory);
  assert.equal(requestCount, afterFirst, "a valid cache entry must not redownload");
});
