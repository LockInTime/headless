import { validateRepositoryContent } from "../lib/repository-content.mjs";

const result = validateRepositoryContent();
if (
  result.benchmarkCases !== 4 ||
  result.commandGroups !== 4 ||
  result.securityRules < 3 ||
  result.productDocRoutes !== 6 ||
  result.commandForms < 30 ||
  result.installMethods !== 4 ||
  result.securityBoundaries < 5 ||
  result.releases < 2
) {
  throw new Error(
    `content provenance validation failed: ${JSON.stringify(result)}`,
  );
}

console.log("Repository content provenance is valid");
