export type BenchmarkWorkflow = {
  case: string;
  label: string;
  workflow: string;
  name: string;
  variant: string;
  color: string;
  tokens: number;
  cpuMs: number;
  wallMs: number;
  memoryMiB: number;
  surface: number;
  formatted: {
    tokens: string;
    wallTime: string;
    cpuTime: string;
    memory: string;
  };
};

export type BenchmarkContent = {
  sectionLabel: string;
  methodDate: string;
  headline: string;
  summary: string;
  proofs: Array<{
    metric: string;
    against: string;
    value: number;
    description: string;
  }>;
  workflows: BenchmarkWorkflow[];
};

export type DocumentationContent = {
  introduction: string;
  firstRunCommands: string;
  qaWorkflowCommands: string;
  startupPresentation: string;
  contextPruning: string;
  scrollableEvidence: string;
  commandGroups: Array<{
    title: string;
    commands: string;
    description: string;
    usage: string;
  }>;
  security: string[];
  platforms: string[];
  markdown: string;
};

export type MarkdownTable = { headers: string[]; rows: string[][] };

export type ProductDocsContent = {
  routes: Array<{ href: string; label: string }>;
  version: string;
  protocolVersion: string;
  install: Array<{ title: string; copy: string[]; commands: string[] }>;
  commands: {
    count: number;
    groups: DocumentationContent["commandGroups"];
  };
  mcp: { copy: string[]; commands: string[]; config: string };
  security: {
    boundary: MarkdownTable;
    limitations: string[];
    hardening: string[];
  };
  platforms: {
    supported: string[];
    comparison: MarkdownTable;
    notes: string[];
  };
  release: {
    version: string;
    date: string;
    summary: string;
    changes: Array<{ title: string; items: string[] }>;
  };
  releases: Array<ProductDocsContent["release"]>;
};

export const PRODUCT_DOC_ROUTES: Array<{ href: string; label: string }>;

export function loadBenchmarkContent(): BenchmarkContent;
export function loadDocumentationContent(): DocumentationContent;
export function loadProductDocsContent(): ProductDocsContent;
export function validateRepositoryContent(): {
  benchmarkCases: number;
  commandGroups: number;
  securityRules: number;
  productDocRoutes: number;
  commandForms: number;
  installMethods: number;
  securityBoundaries: number;
  releases: number;
};
