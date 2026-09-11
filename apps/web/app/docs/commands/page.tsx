import { CommandDirectory } from "@/components/command-directory";
import { DocsShell } from "@/components/docs-shell";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Command reference",
  "The complete generated Headless CLI command reference, grouped by lifecycle, interaction, evidence, and diagnostics.",
  "/docs/commands",
);

export default function CommandsPage() {
  const { commands } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/commands"
      sections={commands.groups.map((group) => ({
        id: group.id,
        label: group.title,
      }))}
      kicker={`${commands.count} command forms`}
      title={<>The complete agent surface.</>}
      lede="These usage lines come from the generated command reference, which protocol tests keep in sync with the CLI help output. Unknown parameters fail closed."
    >
      <CommandDirectory groups={commands.groups} />
    </DocsShell>
  );
}
