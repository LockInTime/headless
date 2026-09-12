import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadProductDocsContent,
  sessionModelFromCommands,
} from "../lib/repository-content.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const commands = await readFile(
  join(root, "apps/headless/docs/COMMANDS.md"),
  "utf8",
);
const sessionModel = sessionModelFromCommands(commands);
assert.match(sessionModel, /one browser profile/i);
assert.doesNotMatch(sessionModel, /stays isolated until you close it/i);

const { commands: surface } = loadProductDocsContent();
assert.ok(
  surface.groups.some((group) => group.title === "Credential vault"),
  "command directory must include Credential vault",
);
assert.ok(
  surface.groups.some((group) => /auth login/.test(group.usage)),
  "command directory must include auth login",
);
assert.doesNotMatch(
  await readFile(join(root, "apps/web/app/docs/commands/page.tsx"), "utf8"),
  /sections=\{commands\.groups/,
);

console.log("command directory content checks passed");
