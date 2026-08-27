import { HeadlessMark } from "@/components/headless-mark";
import { ThemeToggle } from "@/components/theme-toggle";
import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Page not found | Headless",
  description: "The requested Headless page does not exist.",
  robots: { index: false, follow: false },
};

export default function NotFound() {
  return (
    <main className="not-found-shell">
      <nav
        className="docs-nav docs-container"
        aria-label="Not found navigation"
      >
        <Link className="brand" href="/" aria-label="Headless home">
          <HeadlessMark className="brand-mark" />
          <span>headless</span>
        </Link>
        <ThemeToggle />
      </nav>
      <div className="not-found-content">
        <p className="docs-label">404 / Unknown route</p>
        <h1>
          Nothing is listening
          <br />
          <em>at this address.</em>
        </h1>
        <p>
          Headless rejects unknown commands, and this site does the same for
          unknown pages.
        </p>
        <div className="not-found-actions">
          <Link href="/docs">Read the docs</Link>
          <Link href="/">Return home</Link>
        </div>
      </div>
    </main>
  );
}
