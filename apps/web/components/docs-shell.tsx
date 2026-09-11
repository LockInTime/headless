import { HeadlessMark } from "@/components/headless-mark";
import { LinkGlyph } from "@/components/link-glyph";
import { ThemeToggle } from "@/components/theme-toggle";
import {
  PRODUCT_DOC_CATEGORIES,
  PRODUCT_DOC_ROUTES,
} from "@/lib/repository-content.mjs";
import Link from "next/link";

export function DocumentationTable({
  headers,
  rows,
}: {
  headers: string[];
  rows: string[][];
}) {
  return (
    <div className="docs-table-wrap">
      <table className="docs-table">
        <thead>
          <tr>
            {headers.map((header) => (
              <th key={header}>{header}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row[0]}>
              {row.map((cell, index) => (
                <td key={`${row[0]}-${headers[index]}`}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function DocsShell({
  activePath,
  kicker,
  title,
  lede,
  children,
  headingAction,
  sections,
}: {
  activePath: string;
  kicker: string;
  title: React.ReactNode;
  lede: string;
  children: React.ReactNode;
  headingAction?: React.ReactNode;
  sections?: Array<{ id: string; label: string }>;
}) {
  return (
    <main className="docs-shell">
      <a className="skip-link" href="#docs-content">
        Skip to content
      </a>
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
          <Link
            className={activePath.startsWith("/docs") ? "active" : ""}
            href="/docs"
          >
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
        <aside className="docs-sidebar" aria-label="Documentation sections">
          {PRODUCT_DOC_CATEGORIES.map((category) => (
            <div className="docs-nav-group" key={category.id}>
              <p>{category.label}</p>
              {PRODUCT_DOC_ROUTES.filter(
                (route) => route.category === category.id,
              ).map((route) => (
                <Link
                  className={activePath === route.href ? "active" : ""}
                  href={route.href}
                  key={route.href}
                  aria-current={activePath === route.href ? "page" : undefined}
                >
                  {route.label}
                </Link>
              ))}
            </div>
          ))}
          {sections && sections.length > 0 ? (
            <nav className="docs-toc" aria-label="On this page">
              <p>On this page</p>
              {sections.map((section) => (
                <a href={`#${section.id}`} key={section.id}>
                  {section.label}
                </a>
              ))}
            </nav>
          ) : null}
        </aside>

        <article className="docs-content" id="docs-content" tabIndex={-1}>
          <div className="docs-heading-row">
            <div className="docs-kicker">
              <span className="status-dot" /> {kicker}
            </div>
            {headingAction}
          </div>
          <h1>{title}</h1>
          <p className="docs-lede">{lede}</p>
          {children}
        </article>
      </div>
    </main>
  );
}
