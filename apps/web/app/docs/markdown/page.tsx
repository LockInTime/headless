import { pageMarkdown } from "@/components/docs-markdown";

export default function DocsMarkdownPage() {
  return <main className="markdown-shell"><div className="markdown-container"><a href="/docs">← Back to docs</a><pre>{pageMarkdown}</pre></div></main>;
}
