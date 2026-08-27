import { loadDocumentationContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Documentation as Markdown",
  "Plain-text Headless documentation for agents and copyable workflows.",
  "/docs/markdown",
);

export default function DocsMarkdownPage() {
  const documentation = loadDocumentationContent();
  return (
    <main className="markdown-shell">
      <div className="markdown-container">
        <a href="/docs">← Back to docs</a>
        <pre>{documentation.markdown}</pre>
      </div>
    </main>
  );
}
