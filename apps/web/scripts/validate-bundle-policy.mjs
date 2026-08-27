import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const web = resolve(root, "apps/web");
const packageJson = JSON.parse(readFileSync(resolve(web, "package.json"), "utf8"));
const dependencies = packageJson.dependencies ?? {};

for (const dependency of [
  "@base-ui/react",
  "@types/three",
  "class-variance-authority",
  "clsx",
  "ogl",
  "postprocessing",
  "recharts",
  "tailwind-merge",
  "three",
]) {
  assert.equal(
    dependencies[dependency],
    undefined,
    `bundle policy: remove unused dependency ${dependency}`,
  );
}

for (const asset of ["scan-dashboard.png", "scan-github.png"]) {
  assert.equal(
    existsSync(resolve(web, "public", asset)),
    false,
    `bundle policy: ${asset} must not be committed`,
  );
}

for (const component of ["benchmark-chart.tsx", "efficiency-chart.tsx", "scan-frame.tsx"]) {
  const source = readFileSync(resolve(web, "components", component), "utf8");
  assert.doesNotMatch(source, /^"use client";/m);
  assert.doesNotMatch(source, /from ["'](?:recharts|three|ogl|postprocessing)["']/);
}

const classNames = readFileSync(resolve(web, "lib/utils.ts"), "utf8");
assert.doesNotMatch(classNames, /from ["'](?:clsx|tailwind-merge)["']/);

console.log("bundle policy: dependency, asset, and server-rendering checks passed");
