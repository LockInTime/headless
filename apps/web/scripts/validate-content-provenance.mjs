import { validateRepositoryContent } from "../lib/repository-content.mjs";

const result = validateRepositoryContent();
if (
  result.benchmarkCases !== 4 ||
  result.commandGroups !== 4 ||
  result.securityRules < 3
) {
  throw new Error(
    `content provenance validation failed: ${JSON.stringify(result)}`,
  );
}

console.log("Repository content provenance is valid");
