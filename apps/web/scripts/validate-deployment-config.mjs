import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const webRoot = resolve(repositoryRoot, "apps/web");
const readRepositoryFile = (path) =>
  readFile(resolve(repositoryRoot, path), "utf8");
const readWebFile = (path) => readFile(resolve(webRoot, path), "utf8");
const config = JSON.parse(await readWebFile("vercel.json"));

assert.deepEqual(config, {
  $schema: "https://openapi.vercel.sh/vercel.json",
  framework: "nextjs",
  buildCommand: "pnpm build",
  devCommand: "pnpm exec next dev --port $PORT",
  outputDirectory: ".next",
});

const productionUrl = "https://headless-web-pi.vercel.app";
const [
  metadata,
  deploymentDocs,
  agentRules,
  nextConfig,
  rootPackage,
  lockfile,
] = await Promise.all([
  readWebFile("lib/site-metadata.ts"),
  readRepositoryFile("docs/DEPLOYMENT.md"),
  readRepositoryFile("AGENTS.md"),
  readWebFile("next.config.ts"),
  readRepositoryFile("package.json"),
  readRepositoryFile("pnpm-lock.yaml"),
]);

const packageJson = JSON.parse(rootPackage);
assert.match(packageJson.packageManager ?? "", /^pnpm@9\./);
assert.match(packageJson.engines?.pnpm ?? "", />=9/);
assert.match(lockfile, /^lockfileVersion: ['"]?9\.0['"]?$/m);
assert.equal(config.installCommand, undefined);

for (const source of [metadata, deploymentDocs, agentRules]) {
  assert.match(source, new RegExp(productionUrl.replaceAll(".", "\\.")));
}

assert.doesNotMatch(JSON.stringify(config), /headers|contentSecurityPolicy/i);
for (const header of [
  "Content-Security-Policy",
  "Permissions-Policy",
  "Referrer-Policy",
  "X-Content-Type-Options",
  "X-Frame-Options",
]) {
  assert.match(nextConfig, new RegExp(`key: "${header}"`));
}
for (const directive of [
  "base-uri 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
]) {
  assert.match(nextConfig, new RegExp(directive.replaceAll("'", "\\'")));
}

console.log("Vercel deployment configuration is consistent");
