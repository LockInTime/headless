import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const launcher =
  "./.agents/skills/headless-computer-use/scripts/headless-mcp.sh";
const expectedJsonConfig = {
  mcpServers: {
    headless: {
      command: launcher,
      args: [],
      env: {},
    },
  },
};

async function read(relativePath) {
  return readFile(join(repoRoot, relativePath), "utf8");
}

for (const configPath of [".mcp.json", ".cursor/mcp.json"]) {
  const config = JSON.parse(await read(configPath));
  assert.deepEqual(
    config,
    expectedJsonConfig,
    `${configPath} must use the repository launcher`,
  );
}

const codexConfig = await read(".codex/config.toml");
assert.equal(
  codexConfig,
  `[mcp_servers.headless]\ncommand = "${launcher}"\nargs = []\n`,
  ".codex/config.toml must use the repository launcher",
);

const claudeSkill = join(repoRoot, ".claude/skills/headless-computer-use");
assert.equal(
  (await lstat(claudeSkill)).isSymbolicLink(),
  true,
  "Claude skill mirror must be a symlink",
);
assert.equal(
  await realpath(claudeSkill),
  await realpath(join(repoRoot, ".agents/skills/headless-computer-use")),
  "Claude skill mirror must target the canonical skill",
);

const launcherScript = await read(
  ".agents/skills/headless-computer-use/scripts/headless-mcp.sh",
);
assert.doesNotMatch(
  launcherScript,
  /(?:--remote-debugging-port|\bnc\b|\bsocat\b)/,
);

const launcherPath = join(repoRoot, launcher.slice(2));
const testDirectory = await mkdtemp(join(tmpdir(), "headless-mcp-launcher-"));
try {
  const stubPath = join(testDirectory, "headless-mcp");
  await writeFile(stubPath, "#!/bin/sh\nprintf 'mcp-stdio-ready\\n'\n", "utf8");
  await chmod(stubPath, 0o700);

  const launched = spawnSync(launcherPath, [], {
    encoding: "utf8",
    env: { ...process.env, HEADLESS_MCP_EXECUTABLE: stubPath },
  });
  assert.equal(launched.status, 0, launched.stderr);
  assert.equal(launched.stdout, "mcp-stdio-ready\n");

  const relativeOverride = spawnSync(launcherPath, [], {
    encoding: "utf8",
    env: { ...process.env, HEADLESS_MCP_EXECUTABLE: "headless-mcp" },
  });
  assert.equal(relativeOverride.status, 1);
  assert.match(relativeOverride.stderr, /must be an absolute path/);

  const unexpectedArgument = spawnSync(launcherPath, ["--listen"], {
    encoding: "utf8",
  });
  assert.equal(unexpectedArgument.status, 1);
  assert.match(unexpectedArgument.stderr, /does not accept arguments/);
} finally {
  await rm(testDirectory, { force: true, recursive: true });
}

const websiteDocs = await read("apps/web/components/docs-markdown.ts");
assert.doesNotMatch(websiteDocs, /hermes-vm|"command":\s*"ssh"/);
assert.match(websiteDocs, /\.cursor\/mcp\.json/);

const claudeInstructions = await read("CLAUDE.md");
assert.match(claudeInstructions, /\.claude\/skills\/headless-computer-use/);
assert.doesNotMatch(claudeInstructions, /not auto-discovered/);

const openAiMetadata = await read(
  ".agents/skills/headless-computer-use/agents/openai.yaml",
);
assert.match(openAiMetadata, /default_prompt: "Use \$headless-computer-use /);
assert.match(openAiMetadata, /policy:\n  allow_implicit_invocation: true/);

console.log("Harness onboarding configuration is consistent");
