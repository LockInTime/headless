import { HeadlessMark } from "@/components/headless-mark";
import { BenchmarkChart } from "@/components/benchmark-chart";
import { BeamsBackground } from "@/components/ui/beams-background";

const commands = [
  ["01", "Visit", "Open a local or authenticated page."],
  ["02", "Act", "Click, fill, press, scroll, and wait by meaning."],
  ["03", "Prove", "Return recordings, screenshots, reports, and diffs."],
];

const capabilities = [
  ["Observe", "Accessible elements, rendered media, console, network, CSS, cookies, and storage—only when the agent needs them."],
  ["Capture", "Browser-pixel MP4 recordings and private PNG artifacts built for frontend QA and PR review."],
  ["Reproduce", "Reusable flows, visual comparisons, throttling, offline mode, and exact API mocks."],
  ["Contain", "A private Unix socket, no exposed DevTools port, bounded commands, and safe navigation rules."],
];

const benchmarks = [
  ["Headless", "warm", "147", "4.753 s", "842 ms", "276 MiB"],
  ["Headless", "cold", "194", "5.002 s", "1.478 s", "279 MiB"],
  ["Selenium", "Python", "410", "3.134 s", "1.900 s", "280 MiB"],
  ["Puppeteer", "", "499", "2.850 s", "2.441 s", "319 MiB"],
];

export default function Home() {
  return (
    <main className="site-shell">
      <section className="hero">
        <BeamsBackground className="hero-beams" />

        <nav className="nav container" aria-label="Main navigation">
          <a className="brand" href="#top" aria-label="Headless home">
            <HeadlessMark className="brand-mark" />
            <span>headless</span>
          </a>
          <div className="nav-links">
            <a href="#workflow">Workflow</a>
            <a href="#capabilities">Capabilities</a>
            <a href="/docs">Docs</a>
            <a href="https://github.com/SarthakWade/headless">GitHub ↗</a>
          </div>
        </nav>

        <div id="top" className="container hero-content">
          <div className="eyebrow"><span className="status-dot" /> Persistent browser control for agents</div>
          <h1>
            Give your agent
            <span> a real browser.</span>
          </h1>
          <p className="hero-copy">
            Headless turns browser QA into a small, inspectable command surface—so an agent can navigate, test, record, and explain without screen coordinates or a brittle script stack.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#workflow">See the workflow <span>↓</span></a>
            <a className="button button-quiet" href="/docs">Read the docs <span>↗</span></a>
          </div>

          <div className="terminal" role="img" aria-label="Example Headless QA command sequence">
            <div className="terminal-head"><span /><span /><span /><p>hermes-vm — headless</p><b>secure local session</b></div>
            <div className="terminal-body">
              <p><i>$</i> headless start <em>✓ ready</em></p>
              <p><i>$</i> headless session create qa</p>
              <p><i>$</i> headless --session qa visit localhost:3000/designers/dashboard</p>
              <p><i>$</i> headless --session qa record start --fps 10</p>
              <p><i>$</i> headless --session qa click --role button --name Continue</p>
              <p><i>$</i> headless --session qa report create --output pr-report.json <em>✓ evidence ready</em></p>
            </div>
          </div>
        </div>

        <div className="hero-footer container"><span>macOS + Linux</span><span>No Python</span><span>No Selenium</span><span>No public debugging port</span></div>
      </section>

      <section className="benchmark" aria-labelledby="benchmark-title">
        <div className="container benchmark-header">
          <div><div className="section-label">P2 benchmark / 17 Jul 2026</div><h2 id="benchmark-title">Smallest agent surface.<br /><em>Measured, not claimed.</em></h2></div>
          <p>One fresh Linux ARM64 container per case. The same dashboard visit, recording, transition, and final screenshot.</p>
        </div>
        <div className="container benchmark-proof" aria-label="Headless token savings">
          <article><span>Against Selenium + Python</span><strong>64<small>%</small></strong><p>fewer estimated agent tokens</p></article>
          <article><span>Against Puppeteer</span><strong>71<small>%</small></strong><p>fewer estimated agent tokens</p></article>
        </div>
        <div className="container benchmark-chart-panel"><div><span>Workflow footprint / lower is better</span><p>Headless warm = 1×</p></div><BenchmarkChart /></div>
        <div className="container benchmark-table-wrap">
          <table className="benchmark-table">
            <thead><tr><th>Workflow</th><th>Estimated tokens</th><th>Wall time</th><th>CPU time</th><th>Peak memory</th></tr></thead>
            <tbody>{benchmarks.map(([name, variant, tokens, wallTime, cpuTime, memory]) => <tr className={name === "Headless" && variant === "warm" ? "benchmark-highlight" : ""} key={`${name}-${variant}`}><td><b>{name}</b>{variant && <span>{variant}</span>}</td><td>{tokens}</td><td>{wallTime}</td><td>{cpuTime}</td><td>{memory}</td></tr>)}</tbody>
          </table>
        </div>
        <div className="container benchmark-footnote"><p><span className="benchmark-definition"><b>Warm</b> starts with the Headless host and session ready. <b>Cold</b> includes starting both.</span><span>Estimated tokens measure workflow source size, not billed LLM tokens. Point-in-time snapshot; repeat before comparing a change.</span></p><a href="https://github.com/SarthakWade/headless/blob/main/apps/headless/docs/BENCHMARK.md">Read the method ↗</a></div>
      </section>

      <section id="workflow" className="section container workflow">
        <div className="section-label">The control loop</div>
        <div className="section-heading"><p>From intent to evidence—</p><h2>without touching the desktop.</h2></div>
        <div className="command-grid">
          {commands.map(([number, title, description]) => (
            <article className="command-card" key={number}>
              <span>{number}</span><h3>{title}</h3><p>{description}</p><div className="card-rule" />
            </article>
          ))}
        </div>
      </section>

      <section id="capabilities" className="section capabilities">
        <div className="container capability-layout">
          <div className="capability-intro">
            <div className="section-label">Made for real QA</div>
            <h2>When the page breaks,<br />the agent can <em>look closer.</em></h2>
            <p>Deep diagnostics are available on demand, not forced into every interaction.</p>
          </div>
          <div className="capability-list">
            {capabilities.map(([title, description], index) => (
              <article key={title} className="capability-row"><span>0{index + 1}</span><div><h3>{title}</h3><p>{description}</p></div><b>↗</b></article>
            ))}
          </div>
        </div>
      </section>

      <section className="section container closing">
        <div className="closing-panel">
          <div><div className="section-label">Run it where your agent runs</div><h2>Your VM has a browser<br />now. <em>Use it.</em></h2></div>
          <div className="closing-action"><p>One CLI protocol. The same commands over MCP. Purpose-built for the last mile of software QA.</p><a className="button button-primary" href="https://github.com/SarthakWade/headless">Open Headless <span>↗</span></a></div>
        </div>
      </section>

      <footer className="wordmark-footer">
        <div className="container footer-meta">
          <span>HEADLESS / AI BROWSER CONTROL</span>
          <span>BUILT FOR AGENTS, NOT POINTERS</span>
          <a href="/docs">DOCUMENTATION ↗</a>
        </div>
        <div className="footer-wordmark" aria-label="headless">headless</div>
      </footer>
    </main>
  );
}
