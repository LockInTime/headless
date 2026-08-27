import { loadDocumentationContent } from "@/lib/repository-content.mjs";

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
