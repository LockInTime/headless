import { lstatSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPOSITORY_ROOT = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const MAX_SOURCE_BYTES = 8 * 1024 * 1024;
const BENCHMARK_CASES = ["headless", "headless-warm", "selenium", "puppeteer"];
const PRESENTATION = {
  headless: { name: "Headless", variant: "cold", color: "var(--teal-ink)" },
  "headless-warm": {
    name: "Headless",
    variant: "warm",
    color: "var(--amber-ink)",
  },
  selenium: { name: "Selenium", variant: "Python", color: "#8A9490" },
  puppeteer: { name: "Puppeteer", variant: "", color: "#5B6469" },
};

let benchmarkCache;
let documentationCache;

function fail(message) {
  throw new Error(`repository content: ${message}`);
}

function readRepositoryFile(relativePath) {
  const path = resolve(REPOSITORY_ROOT, relativePath);
  const metadata = lstatSync(path);
  if (
    !metadata.isFile() ||
    metadata.size === 0 ||
    metadata.size > MAX_SOURCE_BYTES
  ) {
    fail(
      `${relativePath} must be a non-empty regular file no larger than ${MAX_SOURCE_BYTES} bytes`,
    );
  }
  return readFileSync(path, "utf8");
}

function assertRecord(value, name) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    fail(`${name} must be an object`);
  }
  return value;
}

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0)
    fail(`${name} must be a positive integer`);
  return value;
}

function parseBenchmarkDocument() {
  let document;
  try {
    document = JSON.parse(
      readRepositoryFile("packages/benchmark-results/results.json"),
    );
  } catch (error) {
    fail(
      `benchmark JSON is invalid: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  assertRecord(document, "benchmark document");
  if (document.schemaVersion !== 1) fail("benchmark schemaVersion must be 1");
  const generatedAt = new Date(document.generatedAt);
  if (
    typeof document.generatedAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(document.generatedAt) ||
    Number.isNaN(generatedAt.valueOf()) ||
    generatedAt.toISOString() !== document.generatedAt.replace("Z", ".000Z")
  ) {
    fail("benchmark generatedAt must be an ISO 8601 timestamp");
  }

  const provenance = assertRecord(document.provenance, "benchmark provenance");
  if (provenance.generator !== "apps/headless/benchmark.sh")
    fail("unexpected benchmark generator");
  if (provenance.method !== "apps/headless/docs/BENCHMARK.md")
    fail("unexpected benchmark method");
  if (!/^linux\/[a-z0-9][a-z0-9_-]{0,31}$/.test(provenance.platform)) {
    fail("benchmark platform must identify a Linux architecture");
  }
  positiveInteger(provenance.repeats, "benchmark repeats");
  if (provenance.aggregation !== "median")
    fail("benchmark aggregation must be median");
  if (provenance.taskAwareInspection !== true)
    fail("benchmark must include task-aware inspection");
  if (
    !Array.isArray(document.cases) ||
    document.cases.length !== BENCHMARK_CASES.length
  ) {
    fail(`benchmark must contain exactly ${BENCHMARK_CASES.length} cases`);
  }

  const cases = new Map();
  for (const entry of document.cases) {
    assertRecord(entry, "benchmark case");
    if (!BENCHMARK_CASES.includes(entry.case) || cases.has(entry.case)) {
      fail(`unexpected or duplicate benchmark case: ${String(entry.case)}`);
    }
    const median = assertRecord(entry.median, `${entry.case} median`);
    for (const metric of [
      "wallMs",
      "cpuMs",
      "memoryPeakBytes",
      "estimatedTokens",
    ]) {
      positiveInteger(median[metric], `${entry.case}.${metric}`);
    }
    cases.set(entry.case, { ...entry, median });
  }
  for (const caseName of BENCHMARK_CASES) {
    if (!cases.has(caseName)) fail(`missing benchmark case: ${caseName}`);
  }

  return { generatedAt, provenance, cases };
}

function comparisonProof(
  metric,
  against,
  baseline,
  comparison,
  lowerDescription,
  higherDescription,
) {
  return {
    metric,
    against,
    value: Math.round(Math.abs(1 - baseline / comparison) * 100),
    description: baseline <= comparison ? lowerDescription : higherDescription,
  };
}

function formatDuration(milliseconds) {
  return milliseconds < 1_000
    ? `${milliseconds} ms`
    : `${(milliseconds / 1_000).toFixed(3)} s`;
}

function formatMemory(bytes) {
  return `${Math.round(bytes / (1024 * 1024))} MiB`;
}

function displayPlatform(platform) {
  const [operatingSystem, architecture] = platform.split("/");
  return `${operatingSystem[0].toUpperCase()}${operatingSystem.slice(1)} ${architecture.toUpperCase()}`;
}

export function loadBenchmarkContent() {
  if (benchmarkCache) return benchmarkCache;
  const { generatedAt, provenance, cases } = parseBenchmarkDocument();
  const warm = cases.get("headless-warm").median;
  const selenium = cases.get("selenium").median;
  const puppeteer = cases.get("puppeteer").median;
  const date = new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(generatedAt);

  const workflows = BENCHMARK_CASES.map((caseName) => {
    const entry = cases.get(caseName);
    const presentation = PRESENTATION[caseName];
    return {
      case: caseName,
      workflow: entry.label.replace(",", ""),
      ...presentation,
      tokens: entry.median.estimatedTokens,
      cpuMs: entry.median.cpuMs,
      wallMs: entry.median.wallMs,
      memoryMiB: Math.round(entry.median.memoryPeakBytes / (1024 * 1024)),
      surface: entry.median.estimatedTokens / warm.estimatedTokens,
      formatted: {
        tokens: String(entry.median.estimatedTokens),
        wallTime: formatDuration(entry.median.wallMs),
        cpuTime: formatDuration(entry.median.cpuMs),
        memory: formatMemory(entry.median.memoryPeakBytes),
      },
    };
  });

  benchmarkCache = {
    sectionLabel: `P2 benchmark / ${date}`,
    headline:
      warm.estimatedTokens ===
      Math.min(...workflows.map((workflow) => workflow.tokens))
        ? "Smallest agent surface."
        : "Measured agent surface.",
    summary: `${provenance.repeats} fresh ${displayPlatform(provenance.platform)} containers per case. The table reports medians for the same dashboard workflow.`,
    proofs: [
      comparisonProof(
        "Tokens",
        "Selenium + Python",
        warm.estimatedTokens,
        selenium.estimatedTokens,
        "fewer estimated agent tokens",
        "more estimated agent tokens",
      ),
      comparisonProof(
        "Tokens",
        "Puppeteer",
        warm.estimatedTokens,
        puppeteer.estimatedTokens,
        "fewer estimated agent tokens",
        "more estimated agent tokens",
      ),
      comparisonProof(
        "CPU time",
        "Selenium + Python",
        warm.cpuMs,
        selenium.cpuMs,
        "less median CPU time",
        "more median CPU time",
      ),
      comparisonProof(
        "CPU time",
        "Puppeteer",
        warm.cpuMs,
        puppeteer.cpuMs,
        "less median CPU time",
        "more median CPU time",
      ),
    ],
    workflows,
  };
  return benchmarkCache;
}

function extractSection(markdown, heading) {
  const marker = `## ${heading}`;
  const start = markdown.indexOf(marker);
  if (start < 0) fail(`missing Markdown section: ${heading}`);
  const contentStart = start + marker.length;
  const nextHeading = markdown.indexOf("\n## ", contentStart);
  return markdown
    .slice(contentStart, nextHeading < 0 ? markdown.length : nextHeading)
    .trim();
}

function normalizeParagraph(value) {
  return value
    .split("\n")
    .map((line) => line.trim())
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

function paragraphs(markdown) {
  return markdown
    .split(/\n\s*\n/)
    .map(normalizeParagraph)
    .filter(
      (value) => value && !value.startsWith("```") && !value.startsWith("- "),
    );
}

function paragraphStarting(markdown, prefix) {
  const paragraph = paragraphs(markdown).find((value) =>
    value.startsWith(prefix),
  );
  if (!paragraph) fail(`missing paragraph beginning with: ${prefix}`);
  return paragraph;
}

function fencedCode(markdown) {
  const match = markdown.match(/```(?:sh)?\n([\s\S]*?)\n```/);
  if (!match) fail("missing fenced command block");
  return match[1].trim();
}

function bulletItems(markdown) {
  const items = [];
  let current = "";
  for (const line of markdown.split("\n")) {
    if (line.startsWith("- ")) {
      if (current) items.push(normalizeParagraph(current));
      current = line.slice(2);
    } else if (current && /^\s{2,}\S/.test(line)) {
      current += ` ${line.trim()}`;
    } else if (current && line.trim() === "") {
      items.push(normalizeParagraph(current));
      current = "";
    }
  }
  if (current) items.push(normalizeParagraph(current));
  return items;
}

function commandNames(usage) {
  const names = [];
  for (const line of usage.split("\n")) {
    if (/^\s/.test(line)) continue;
    for (const alternative of line.split(" | ")) {
      const match = alternative.trim().match(/^([a-z][a-z-]*)/);
      if (match && !names.includes(match[1])) names.push(match[1]);
    }
  }
  return names.slice(0, 6).join(", ");
}

function commandGroup(commandReference, title) {
  const section = extractSection(commandReference, title);
  const usage = fencedCode(section);
  const description = bulletItems(section)[0];
  if (!description) fail(`missing command description: ${title}`);
  return { title, commands: commandNames(usage), description, usage };
}

function markdownForDocumentation(content) {
  const groups = content.commandGroups
    .map(
      (group) =>
        `### ${group.title}\n\n\`\`\`sh\n${group.usage}\n\`\`\`\n\n${group.description}`,
    )
    .join("\n\n");
  return `# Headless documentation

${content.introduction}

## First run

\`\`\`sh
${content.firstRunCommands}
\`\`\`

${content.startupPresentation}

## QA workflow

\`\`\`sh
${content.qaWorkflowCommands}
\`\`\`

## Command groups

${groups}

## Context pruning

${content.contextPruning}

## Scrollable page evidence

${content.scrollableEvidence}

## Safety

${content.security.map((item) => `- ${item}`).join("\n")}

## Platforms

${content.platforms.map((item) => `- ${item}`).join("\n")}`;
}

export function loadDocumentationContent() {
  if (documentationCache) return documentationCache;
  const readme = readRepositoryFile("README.md");
  const commandReference = readRepositoryFile("apps/headless/docs/COMMANDS.md");
  const workflowSection = extractSection(readme, "Agent workflow");
  const workflowCommands = fencedCode(workflowSection)
    .split("\n")
    .filter(Boolean);
  const firstRunCommands = workflowCommands.slice(0, 4).join("\n");
  const qaPrefixes = [
    "record start",
    "click",
    "wait",
    "record stop",
    "qa report",
  ];
  const qaWorkflowCommands = workflowCommands
    .filter((line) =>
      qaPrefixes.some((prefix) =>
        line.startsWith(`headless --session qa ${prefix}`),
      ),
    )
    .join("\n");
  if (
    firstRunCommands.split("\n").length !== 4 ||
    qaWorkflowCommands.split("\n").length !== 5
  ) {
    fail(
      "README agent workflow no longer contains the expected first-run and QA sequence",
    );
  }

  const content = {
    introduction: paragraphStarting(readme, "Persistent browser control"),
    firstRunCommands,
    qaWorkflowCommands,
    startupPresentation: paragraphStarting(workflowSection, "On macOS"),
    contextPruning: paragraphStarting(
      workflowSection,
      "Inspection is progressively disclosed",
    ),
    scrollableEvidence: paragraphStarting(
      workflowSection,
      "For scrollable-page QA",
    ),
    commandGroups: [
      commandGroup(commandReference, "Host lifecycle"),
      commandGroup(commandReference, "Navigation and interaction"),
      commandGroup(commandReference, "Capture and evidence"),
      commandGroup(commandReference, "Diagnostics"),
    ],
    security: bulletItems(extractSection(readme, "Security boundary")),
    platforms: bulletItems(
      readme.slice(0, readme.indexOf("## Computer use comparison")),
    ).filter((item) => item.startsWith("macOS") || item.startsWith("Linux")),
  };
  if (content.security.length < 3 || content.platforms.length !== 2) {
    fail("README security or platform contract is incomplete");
  }

  documentationCache = {
    ...content,
    markdown: markdownForDocumentation(content),
  };
  return documentationCache;
}

export function validateRepositoryContent() {
  const benchmark = loadBenchmarkContent();
  const documentation = loadDocumentationContent();
  return {
    benchmarkCases: benchmark.workflows.length,
    commandGroups: documentation.commandGroups.length,
    securityRules: documentation.security.length,
  };
}
