import { CommandBlock, CopyPageButton } from "@/components/docs-copy-controls";
import { HeadlessMark } from "@/components/headless-mark";
import { ThemeToggle } from "@/components/theme-toggle";
import Link from "next/link";

const coreCommands = [
  ["Navigation", "visit, back, reload, wait", "Move through a real browser session and wait for a URL, page text, or settled state."],
  ["Interaction", "inspect, click, fill, press, scroll", "Use accessibility roles and names instead of mouse coordinates or selectors."],
  ["Evidence", "screenshot, record, visual compare, report", "Create private PNG, MP4, diff, flow, and PR-report artifacts."],
  ["Diagnostics", "console, network, styles, cookies, storage", "Investigate only when something fails; sensitive values remain redacted by default."],
];

export default function DocsPage() {
  return (
    <main className="docs-shell">
      <nav className="docs-nav docs-container" aria-label="Documentation navigation">
        <Link className="brand" href="/" aria-label="Headless home"><HeadlessMark className="brand-mark" /><span>headless</span></Link>
        <div><Link href="/">Overview</Link><Link className="active" href="/docs">Docs</Link><a href="https://github.com/SarthakWade/headless">GitHub ↗</a><ThemeToggle /></div>
      </nav>

      <div className="docs-container docs-layout">
        <aside className="docs-sidebar">
          <p>GET STARTED</p>
          <a href="#first-run">First run</a><a href="#workflow">QA workflow</a><a href="#commands">Core commands</a><a href="#safety">Safety</a>
          <p>PLATFORMS</p>
          <a href="#linux">Linux + Docker</a><a href="#macos">macOS</a>
        </aside>

        <article className="docs-content">
          <div className="docs-heading-row"><div className="docs-kicker"><span className="status-dot" /> Headless documentation</div><CopyPageButton /></div>
          <h1>Browser control,<br /><em>made useful.</em></h1>
          <p className="docs-lede">Headless gives an agent a persistent browser through a small, safe CLI. Test a page, capture evidence, and inspect a failure.</p>

          <section id="first-run">
            <p className="docs-label">01 / First run</p>
            <h2>Start a session.</h2>
            <p>Start the host, create a session, then visit the app. The session stays isolated until you close it.</p>
            <CommandBlock>{`headless start\nheadless session create qa\nheadless --session qa visit localhost:3000/designers/dashboard\nheadless --session qa inspect --interactive --text`}</CommandBlock>
          </section>

          <section id="workflow">
            <p className="docs-label">02 / A QA workflow</p>
            <h2>Capture the proof.</h2>
            <p>Record the path you need, then stop and create a report.</p>
            <CommandBlock>{`headless --session qa record start --fps 10\nheadless --session qa click --role button --name Continue\nheadless --session qa wait --url /next --settled\nheadless --session qa record stop --output dashboard-flow.mp4\nheadless --session qa report create --output pr-report.json`}</CommandBlock>
          </section>

          <section id="commands">
            <p className="docs-label">03 / Command groups</p>
            <h2>Use intent, not pixels.</h2>
            <div className="docs-command-grid">
              {coreCommands.map(([title, commands, description]) => <div className="docs-command" key={title}><h3>{title}</h3><code>{commands}</code><p>{description}</p></div>)}
            </div>
          </section>

          <section id="safety">
            <p className="docs-label">04 / Safety by default</p>
            <h2>Keep the browser local.</h2>
            <p>Headless uses a private Unix socket, not a public DevTools port. Only HTTP(S) navigation is allowed. Diagnostic secrets are redacted.</p>
          </section>

          <section id="linux" className="docs-note"><p><b>Linux:</b> use the supplied Docker runtime or native Chromium. Ubuntu Snap Chromium is not supported for repeated navigation.</p></section>
          <section id="macos" className="docs-note"><p><b>macOS:</b> build with Xcode Command Line Tools, then use the visible WKWebView host through the same CLI.</p></section>
        </article>
      </div>
    </main>
  );
}
