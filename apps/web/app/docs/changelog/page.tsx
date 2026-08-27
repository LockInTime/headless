import { DocsShell } from "@/components/docs-shell";
import { plainText } from "@/lib/markdown";
import { loadProductDocsContent } from "@/lib/repository-content.mjs";
import { docsMetadata } from "@/lib/site-metadata";

export const metadata = docsMetadata(
  "Changelog",
  "Current Headless product and protocol versions, with the latest release notes.",
  "/docs/changelog",
);

export default function ChangelogPage() {
  const { protocolVersion, release, releases } = loadProductDocsContent();
  return (
    <DocsShell
      activePath="/docs/changelog"
      kicker={`Released / ${release.date}`}
      title={
        <>
          Headless <em>v{release.version}</em>
        </>
      }
      lede={plainText(release.summary)}
    >
      <div className="docs-version-strip" aria-label="Current versions">
        <div>
          <span>Product</span>
          <strong>v{release.version}</strong>
        </div>
        <div>
          <span>Protocol</span>
          <strong>{protocolVersion}</strong>
        </div>
      </div>
      {release.changes.map((group, index) => (
        <section key={group.title}>
          <p className="docs-label">
            {String(index + 1).padStart(2, "0")} / {group.title}
          </p>
          <h2>{group.title}</h2>
          <ul className="docs-list">
            {group.items.map((item) => (
              <li key={item}>{plainText(item)}</li>
            ))}
          </ul>
        </section>
      ))}
      <section>
        <p className="docs-label">Release history</p>
        <h2>Earlier versions.</h2>
        <div className="docs-release-history">
          {releases.slice(1).map((earlier) => (
            <article key={earlier.version}>
              <header>
                <h3>v{earlier.version}</h3>
                <time dateTime={earlier.date}>{earlier.date}</time>
              </header>
              {earlier.changes.map((group) => (
                <div key={group.title}>
                  <h4>{group.title}</h4>
                  <ul className="docs-list docs-list-compact">
                    {group.items.map((item) => (
                      <li key={item}>{plainText(item)}</li>
                    ))}
                  </ul>
                </div>
              ))}
            </article>
          ))}
        </div>
      </section>
    </DocsShell>
  );
}
