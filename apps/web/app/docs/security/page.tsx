import { DocsShell, DocumentationTable } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Security model",
  "Understand Headless security boundaries, known limitations, and operator hardening guidance.",
  "/docs/security",
);

export default function SecurityPage() {
  const { security } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/security"
      kicker="Fail closed by contract"
      title={<>Local control. Bounded output.</>}
      lede="Headless exposes no TCP listener, no Chromium debug port, and no arbitrary-JavaScript command. This page separates reportable boundary failures from documented limits."
    >
      <section>
        <p className="docs-label">01 / Security boundaries</p>
        <h2>What must hold.</h2>
        <DocumentationTable
          headers={security.boundary.headers.map(plainText)}
          rows={security.boundary.rows.map((row) => row.map(plainText))}
        />
      </section>
      <section>
        <p className="docs-label">02 / Known limitations</p>
        <h2>Documented, not hidden.</h2>
        <ul className="docs-list">
          {security.limitations.map((item) => (
            <li key={item}>{plainText(item)}</li>
          ))}
        </ul>
      </section>
      <section>
        <p className="docs-label">03 / Operator hardening</p>
        <h2>Reduce the same-user boundary.</h2>
        <ul className="docs-list">
          {security.hardening.map((item) => (
            <li key={item}>{plainText(item)}</li>
          ))}
        </ul>
      </section>
    </DocsShell>
  );
}
