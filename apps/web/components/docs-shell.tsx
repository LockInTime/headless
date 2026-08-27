import { HeadlessMark } from "@/components/headless-mark";
import { LinkGlyph } from "@/components/link-glyph";
import { ThemeToggle } from "@/components/theme-toggle";
import { PRODUCT_DOC_ROUTES } from "@/lib/repository-content.mjs";
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
}: {
  activePath: string;
  kicker: string;
  title: React.ReactNode;
  lede: string;
  children: React.ReactNode;
  headingAction?: React.ReactNode;
}) {
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
        <aside className="docs-sidebar" aria-label="Documentation sections">
          <p>DOCUMENTATION</p>
          <Link className={activePath === "/docs" ? "active" : ""} href="/docs">
            Overview
          </Link>
          {PRODUCT_DOC_ROUTES.slice(0, 3).map((route) => (
            <Link
              className={activePath === route.href ? "active" : ""}
              href={route.href}
              key={route.href}
            >
              {route.label}
            </Link>
          ))}
          <p>TRUST &amp; SUPPORT</p>
          {PRODUCT_DOC_ROUTES.slice(3).map((route) => (
            <Link
              className={activePath === route.href ? "active" : ""}
              href={route.href}
              key={route.href}
            >
              {route.label}
            </Link>
          ))}
        </aside>

        <article className="docs-content">
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
