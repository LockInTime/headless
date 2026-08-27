import { CommandBlock, CopyPageButton } from "@/components/docs-copy-controls";
import { DocsShell } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadDocumentationContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Documentation",
  "Start Headless, run semantic browser workflows, capture evidence, and understand its safety defaults.",
  "/docs",
);

export default function DocsPage() {
  const documentation = loadDocumentationContent();

  return (
    <DocsShell
      activePath="/docs"
      kicker="Headless documentation"
      title={
        <>
          Browser control,
          <br />
          <em>made useful.</em>
        </>
      }
      lede={plainText(documentation.introduction)}
      headingAction={<CopyPageButton pageMarkdown={documentation.markdown} />}
    >
      <section id="first-run">
        <p className="docs-label">01 / First run</p>
        <h2>Start a session.</h2>
        <p>
          Start the host, create a session, then visit the app. The session
          stays isolated until you close it.
        </p>
        <CommandBlock>{documentation.firstRunCommands}</CommandBlock>
        <p>{plainText(documentation.startupPresentation)}</p>
      </section>

      <section id="workflow">
        <p className="docs-label">02 / A QA workflow</p>
        <h2>Capture the proof.</h2>
        <p>Record the path you need, then stop and create a report.</p>
        <CommandBlock>{documentation.qaWorkflowCommands}</CommandBlock>
      </section>

      <section id="commands">
        <p className="docs-label">03 / Command groups</p>
        <h2>Use intent, not pixels.</h2>
        <div className="docs-command-grid">
          {documentation.commandGroups.map((group) => (
            <div className="docs-command" key={group.title}>
              <h3>{group.title}</h3>
              <code>{group.commands}</code>
              <p>{plainText(group.description)}</p>
            </div>
          ))}
        </div>
      </section>

      <section id="context">
        <p className="docs-label">04 / Context pruning</p>
        <h2>Reveal only what matters.</h2>
        <p>{plainText(documentation.contextPruning)}</p>
      </section>

      <section id="scrollable">
        <p className="docs-label">05 / Scrollable evidence</p>
        <h2>Capture the whole scroll.</h2>
        <p>{plainText(documentation.scrollableEvidence)}</p>
      </section>

      <section id="safety">
        <p className="docs-label">06 / Safety by default</p>
        <h2>Keep the browser local.</h2>
        <p>{plainText(documentation.security.slice(0, 3).join(" "))}</p>
      </section>

      {documentation.platforms.map((platform) => {
        const name = platform.startsWith("macOS") ? "macOS" : "Linux";
        return (
          <section id={name.toLowerCase()} className="docs-note" key={name}>
            <p>
              <b>{name}:</b>{" "}
              {plainText(platform).replace(
                new RegExp(`^${name}[^:]*:\\s*`),
                "",
              )}
            </p>
          </section>
        );
      })}
    </DocsShell>
  );
}
