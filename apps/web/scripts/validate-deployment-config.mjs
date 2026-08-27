import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const read = (path) => readFile(resolve(root, path), "utf8");
const config = JSON.parse(await read("vercel.json"));

assert.deepEqual(config, {
  $schema: "https://openapi.vercel.sh/vercel.json",
  framework: "nextjs",
  buildCommand: "pnpm --filter @headless/web build",
  devCommand: "pnpm --filter @headless/web exec next dev --port $PORT",
  outputDirectory: "apps/web/.next",
});

const productionUrl = "https://headless-web-pi.vercel.app";
const [metadata, deploymentDocs, agentRules, nextConfig, rootPackage, lockfile] =
  await Promise.all([
    read("apps/web/lib/site-metadata.ts"),
    read("docs/DEPLOYMENT.md"),
    read("AGENTS.md"),
    read("apps/web/next.config.ts"),
    read("package.json"),
    read("pnpm-lock.yaml"),
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
