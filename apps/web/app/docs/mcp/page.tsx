import { CommandBlock } from "@/components/docs-copy-controls";
import { DocsShell } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "MCP setup",
  "Connect an MCP client to Headless over stdio without exposing a browser-control port.",
  "/docs/mcp",
);

export default function McpPage() {
  const { mcp } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/mcp"
      kicker="One stdio tool"
      title={<>Connect without a control port.</>}
      lede={plainText(mcp.copy[0])}
    >
      <section>
        <p className="docs-label">01 / Project configuration</p>
        <h2>Use the checked-in launcher.</h2>
        <p>
          Add this configuration at the project root. The launcher selects the
          repository runtime and exposes the normal CLI argument list as one MCP
          tool.
        </p>
        <CommandBlock>{mcp.config}</CommandBlock>
      </section>
      <section>
        <p className="docs-label">02 / Remote agent</p>
        <h2>Tunnel stdio, not DevTools.</h2>
        <p>{plainText(mcp.copy[1])}</p>
        {mcp.commands.map((commands) => (
          <CommandBlock key={commands}>{commands}</CommandBlock>
        ))}
      </section>
      <section className="docs-note">
        <p>
          The tool can stop the host and close sessions. MCP annotations mark it
          mutating, destructive, non-idempotent, and open-world so clients can
          apply their own confirmation policy.
        </p>
      </section>
    </DocsShell>
  );
}
