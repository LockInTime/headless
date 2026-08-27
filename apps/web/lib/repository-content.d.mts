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

export function loadBenchmarkContent(): BenchmarkContent;
export function loadDocumentationContent(): DocumentationContent;
export function validateRepositoryContent(): {
  benchmarkCases: number;
  commandGroups: number;
  securityRules: number;
};
