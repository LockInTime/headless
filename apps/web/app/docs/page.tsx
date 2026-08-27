import { CommandBlock, CopyPageButton } from "@/components/docs-copy-controls";
import { HeadlessMark } from "@/components/headless-mark";
import { LinkGlyph } from "@/components/link-glyph";
import { ThemeToggle } from "@/components/theme-toggle";
import { loadDocumentationContent } from "@/lib/repository-content.mjs";
import Link from "next/link";

function plainText(markdown: string) {
  return markdown
    .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
    .replaceAll("`", "")
    .replaceAll("**", "");
}

export default function DocsPage() {
  const documentation = loadDocumentationContent();

  return (
    <main className="docs-shell">
      <nav
        className="docs-nav docs-container"
        aria-label="Documentation navigation"
      >
        <Link className="brand" href="/" aria-label="Headless home">
          <HeadlessMark className="brand-mark" />
          <span>headless</span>
        </Link>
        <div>
          <Link href="/">Overview</Link>
          <Link className="active" href="/docs">
            Docs
          </Link>
          <a
            className="nav-external"
            href="https://github.com/LockInTime/headless"
          >
            GitHub <LinkGlyph kind="external" />
          </a>
          <ThemeToggle />
        </div>
      </nav>

      <div className="docs-container docs-layout">
        <aside className="docs-sidebar">
          <p>GET STARTED</p>
          <a href="#first-run">First run</a>
          <a href="#workflow">QA workflow</a>
          <a href="#commands">Core commands</a>
          <a href="#context">Context pruning</a>
          <a href="#scrollable">Scrollable evidence</a>
          <a href="#safety">Safety</a>
          <p>PLATFORMS</p>
          <a href="#linux">Linux + Docker</a>
          <a href="#macos">macOS</a>
        </aside>

        <article className="docs-content">
          <div className="docs-heading-row">
            <div className="docs-kicker">
              <span className="status-dot" /> Headless documentation
            </div>
            <CopyPageButton pageMarkdown={documentation.markdown} />
          </div>
          <h1>
            Browser control,
            <br />
            <em>made useful.</em>
          </h1>
          <p className="docs-lede">{plainText(documentation.introduction)}</p>

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
        </article>
      </div>
    </main>
  );
}
