import { CommandBlock } from "@/components/docs-copy-controls";
import { DocsShell } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Install",
  "Install Headless on macOS, Linux, WSL2, or through the verified npm launcher.",
  "/docs/install",
);

export default function InstallPage() {
  const { install, version } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/install"
      kicker={`Current release / v${version}`}
      title={<>Choose your runtime.</>}
      lede="Use a signed native package, the checksum-verified Linux bootstrap, WSL2, or the npm launcher. Every path keeps browser control on a private local socket."
    >
      {install.map((method, index) => (
        <section
          id={method.title.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}
          key={method.title}
        >
          <p className="docs-label">
            {String(index + 1).padStart(2, "0")} / {method.title}
          </p>
          <h2>{method.title}</h2>
          {method.copy.slice(0, 2).map((paragraph) => (
            <p key={paragraph}>{plainText(paragraph)}</p>
          ))}
          {method.commands.map((commands) => (
            <CommandBlock key={commands}>{commands}</CommandBlock>
          ))}
        </section>
      ))}
    </DocsShell>
  );
}
