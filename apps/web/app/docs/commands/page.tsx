import { CommandBlock } from "@/components/docs-copy-controls";
import { DocsShell } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
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
      kicker={`${commands.count} command forms`}
      title={<>The complete agent surface.</>}
      lede="These usage lines come from the generated command reference, which protocol tests keep in sync with the CLI help output. Unknown parameters fail closed."
    >
      {commands.groups.map((group, index) => (
        <section
          id={group.title.toLowerCase().replaceAll(" ", "-")}
          key={group.title}
        >
          <p className="docs-label">
            {String(index + 1).padStart(2, "0")} / {group.title}
          </p>
          <h2>{group.title}</h2>
          <p>{plainText(group.description)}</p>
          <CommandBlock>{group.usage}</CommandBlock>
        </section>
      ))}
    </DocsShell>
  );
}
