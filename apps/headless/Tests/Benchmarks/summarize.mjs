import {
  chmodSync,
  closeSync,
  constants,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

const CASES = [
  ["headless", "Headless, cold"],
  ["headless-warm", "Headless, warm"],
  ["selenium", "Selenium with Python"],
  ["puppeteer", "Puppeteer"],
];
const METRICS = [
  "wallMs",
  "cpuMs",
  "memoryPeakBytes",
  "artifactBytes",
  "workflowBytes",
  "estimatedTokens",
];
const EXPECTED_KEYS = ["case", ...METRICS].sort();
const MAX_INPUT_BYTES = 8 * 1024 * 1024;

function fail(message) {
  console.error(`benchmark summary: ${message}`);
  process.exit(65);
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function parsePositiveInteger(value, name, maximum) {
  if (!/^[1-9][0-9]*$/.test(value)) fail(`${name} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed > maximum) {
    fail(`${name} must not exceed ${maximum}`);
  }
  return parsed;
}

function parseRecords(inputPath, repeats) {
  const inputStat = statSync(inputPath);
  if (!inputStat.isFile() || inputStat.size === 0 || inputStat.size > MAX_INPUT_BYTES) {
    fail(`input must be a non-empty regular file no larger than ${MAX_INPUT_BYTES} bytes`);
  }

  const lines = readFileSync(inputPath, "utf8").split("\n").filter((line) => line.length > 0);
  if (lines.length !== CASES.length * repeats) {
    fail(`expected ${CASES.length * repeats} samples, received ${lines.length}`);
  }

  return lines.map((line, index) => {
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      fail(`sample ${index + 1} is not valid JSON`);
    }
    if (record === null || Array.isArray(record) || typeof record !== "object") {
      fail(`sample ${index + 1} must be an object`);
    }
    if (JSON.stringify(Object.keys(record).sort()) !== JSON.stringify(EXPECTED_KEYS)) {
      fail(`sample ${index + 1} has an unexpected schema`);
    }
    if (!CASES.some(([caseName]) => caseName === record.case)) {
      fail(`sample ${index + 1} has an unknown case`);
    }
    for (const metric of METRICS) {
      if (!Number.isSafeInteger(record[metric]) || record[metric] < 0) {
        fail(`sample ${index + 1} has an invalid ${metric}`);
      }
    }
    return record;
  });
}

function aggregate(records, repeats) {
  return CASES.map(([caseName, label]) => {
    const caseRecords = records.filter((record) => record.case === caseName);
    if (caseRecords.length !== repeats) {
      fail(`${caseName} must have exactly ${repeats} samples`);
    }
    for (const metric of ["workflowBytes", "estimatedTokens"]) {
      if (new Set(caseRecords.map((record) => record[metric])).size !== 1) {
        fail(`${caseName} has inconsistent ${metric} values`);
      }
    }

    return {
      case: caseName,
      label,
      samples: caseRecords.map((record, index) => ({
        iteration: index + 1,
        ...Object.fromEntries(METRICS.map((metric) => [metric, record[metric]])),
      })),
      median: Object.fromEntries(
        METRICS.map((metric) => [metric, median(caseRecords.map((record) => record[metric]))]),
      ),
    };
  });
}

function writeAtomically(outputPath, document) {
  const outputDirectory = dirname(outputPath);
  mkdirSync(outputDirectory, { recursive: true });
  const temporaryPath = join(
    outputDirectory,
    `.${basename(outputPath)}.${process.pid}.${Date.now()}.tmp`,
  );
  let descriptor;
  try {
    descriptor = openSync(
      temporaryPath,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
      0o600,
    );
    writeFileSync(descriptor, `${JSON.stringify(document, null, 2)}\n`, "utf8");
    closeSync(descriptor);
    descriptor = undefined;
    chmodSync(temporaryPath, 0o644);
    renameSync(temporaryPath, outputPath);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporaryPath, { force: true });
  }
}

if (process.argv.length !== 7) {
  console.error("usage: summarize.mjs INPUT OUTPUT REPEATS GENERATED_AT PLATFORM");
  process.exit(64);
}

const [, , inputPath, outputPath, repeatsValue, generatedAt, platform] = process.argv;
const repeats = parsePositiveInteger(repeatsValue, "repeats", 100);
const parsedTimestamp = new Date(generatedAt);
if (
  !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(generatedAt)
  || Number.isNaN(parsedTimestamp.valueOf())
  || parsedTimestamp.toISOString() !== generatedAt.replace("Z", ".000Z")
) {
  fail("generated timestamp must be UTC ISO 8601 without fractional seconds");
}
if (!/^linux\/[a-z0-9][a-z0-9_-]{0,31}$/.test(platform)) {
  fail("platform must identify a Linux container architecture");
}

const records = parseRecords(inputPath, repeats);
const document = {
  schemaVersion: 1,
  generatedAt,
  provenance: {
    generator: "apps/headless/benchmark.sh",
    method: "apps/headless/docs/BENCHMARK.md",
    platform,
    repeats,
    aggregation: "median",
    taskAwareInspection: true,
  },
  cases: aggregate(records, repeats),
};
writeAtomically(outputPath, document);
