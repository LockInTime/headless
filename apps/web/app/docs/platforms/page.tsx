import { DocsShell, DocumentationTable } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Platforms and comparison",
  "Compare Headless platform support and qualitative browser-computer-use tradeoffs.",
  "/docs/platforms",
);

export default function PlatformsPage() {
  const { platforms } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/platforms"
      kicker="macOS + Linux"
      title={<>Two engines. One contract.</>}
      lede="Headless uses WKWebView on macOS and sandboxed Chromium on Linux. Capability differences are explicit and unsupported operations return errors instead of partial behavior."
    >
      <section>
        <p className="docs-label">01 / Supported hosts</p>
        <h2>Native where it runs.</h2>
        <div className="docs-card-grid">
          {platforms.supported.map((platform) => (
            <article className="docs-card" key={platform}>
              <h3>{platform.startsWith("macOS") ? "macOS" : "Linux"}</h3>
              <p>{plainText(platform)}</p>
            </article>
          ))}
        </div>
      </section>
      <section>
        <p className="docs-label">02 / Computer-use comparison</p>
        <h2>Choose for the actual job.</h2>
        <p>
          Scores are qualitative capability judgments from the README, not
          benchmark measurements.
        </p>
        <DocumentationTable
          headers={platforms.comparison.headers.map(plainText)}
          rows={platforms.comparison.rows.map((row) => row.map(plainText))}
        />
        <ul className="docs-list docs-list-compact">
          {platforms.notes.map((note) => (
            <li key={note}>{plainText(note)}</li>
          ))}
        </ul>
      </section>
    </DocsShell>
  );
}
