import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const testRoot = mkdtempSync(join(tmpdir(), "headless-benchmark-summary."));
const appRoot = fileURLToPath(new URL("..", import.meta.url));
const summarizer = join(appRoot, "Tests/Benchmarks/summarize.mjs");
const coldWorkflow = readFileSync(join(appRoot, "Tests/Benchmarks/headless.sh"), "utf8");
const warmWorkflow = readFileSync(join(appRoot, "Tests/Benchmarks/headless_warm.sh"), "utf8");

function sample(caseName, value, workflowBytes) {
  return {
    case: caseName,
    wallMs: value,
    cpuMs: value + 10,
    memoryPeakBytes: value + 20,
    artifactBytes: value + 30,
    workflowBytes,
    estimatedTokens: Math.ceil(workflowBytes / 4),
  };
}

function run(records, repeats, name = "results.json") {
  const input = join(testRoot, `${name}.ndjson`);
  const output = join(testRoot, name);
  writeFileSync(input, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`);
  const result = spawnSync(
    process.execPath,
    [summarizer, input, output, String(repeats), "2026-08-12T10:00:00Z", "linux/arm64"],
    { encoding: "utf8" },
  );
  return { ...result, output };
}

try {
  for (const workflow of [coldWorkflow, warmWorkflow]) {
    assert.match(workflow, /inspect --context actions --task 'continue to designer details'/);
    assert.match(workflow, /--limit 8 --budget 700/);
  }

  const oddRecords = [];
  for (const [caseName, workflowBytes] of [
    ["headless", 800],
    ["headless-warm", 600],
    ["selenium", 1600],
    ["puppeteer", 2000],
  ]) {
    oddRecords.push(sample(caseName, 30, workflowBytes));
    oddRecords.push(sample(caseName, 10, workflowBytes));
    oddRecords.push(sample(caseName, 20, workflowBytes));
  }
  const odd = run(oddRecords, 3);
  assert.equal(odd.status, 0, odd.stderr);
  const document = JSON.parse(readFileSync(odd.output, "utf8"));
  assert.equal(document.schemaVersion, 1);
  assert.equal(document.provenance.repeats, 3);
  assert.equal(document.provenance.aggregation, "median");
  assert.equal(document.provenance.taskAwareInspection, true);
  assert.deepEqual(document.cases.map((entry) => entry.case), [
    "headless",
    "headless-warm",
    "selenium",
    "puppeteer",
  ]);
  assert.equal(document.cases[0].median.wallMs, 20);
  assert.deepEqual(document.cases[0].samples.map((entry) => entry.iteration), [1, 2, 3]);
  const firstOutput = readFileSync(odd.output, "utf8");
  const oddAgain = run(oddRecords, 3);
  assert.equal(oddAgain.status, 0, oddAgain.stderr);
  assert.equal(readFileSync(oddAgain.output, "utf8"), firstOutput);

  const evenRecords = [];
  for (const [caseName, workflowBytes] of [
    ["headless", 800],
    ["headless-warm", 600],
    ["selenium", 1600],
    ["puppeteer", 2000],
  ]) {
    evenRecords.push(sample(caseName, 10, workflowBytes));
    evenRecords.push(sample(caseName, 11, workflowBytes));
  }
  const even = run(evenRecords, 2, "even.json");
  assert.equal(even.status, 0, even.stderr);
  assert.equal(JSON.parse(readFileSync(even.output, "utf8")).cases[0].median.wallMs, 10.5);

  const missing = run(oddRecords.slice(1), 3, "missing.json");
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /expected 12 samples/);

  const unknown = run(
    [{ ...oddRecords[0], case: "unknown" }, ...oddRecords.slice(1)],
    3,
    "unknown.json",
  );
  assert.notEqual(unknown.status, 0);
  assert.match(unknown.stderr, /unknown case/);

  const inconsistent = run(
    [{ ...oddRecords[0], workflowBytes: 801 }, ...oddRecords.slice(1)],
    3,
    "inconsistent.json",
  );
  assert.notEqual(inconsistent.status, 0);
  assert.match(inconsistent.stderr, /inconsistent workflowBytes/);

  const malformed = run(
    [{ ...oddRecords[0], wallMs: -1 }, ...oddRecords.slice(1)],
    3,
    "malformed.json",
  );
  assert.notEqual(malformed.status, 0);
  assert.match(malformed.stderr, /invalid wallMs/);

  writeFileSync(malformed.output, "preserve existing result\n");
  const malformedAgain = run(
    [{ ...oddRecords[0], wallMs: -1 }, ...oddRecords.slice(1)],
    3,
    "malformed.json",
  );
  assert.notEqual(malformedAgain.status, 0);
  assert.equal(readFileSync(malformed.output, "utf8"), "preserve existing result\n");
} finally {
  rmSync(testRoot, { recursive: true, force: true });
}

console.log("Benchmark summary tests passed");
