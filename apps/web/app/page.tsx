import { HeadlessMark } from "@/components/headless-mark";
import { BenchmarkChart } from "@/components/benchmark-chart";
import { EfficiencyChart } from "@/components/efficiency-chart";
import { BeamsBackground } from "@/components/ui/beams-background";
import { PixelBlast } from "@/components/ui/pixel-blast";
import { ScanFrame } from "@/components/scan-frame";
import { ThemeToggle } from "@/components/theme-toggle";
import { LinkGlyph } from "@/components/link-glyph";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { ArrowDownIcon, ArrowUpRightIcon } from "lucide-react";

const commands = [
  ["01", "Visit", "Open a local or authenticated page."],
  ["02", "Act", "Click, fill, press, scroll, and wait by meaning."],
  ["03", "Prove", "Return recordings, screenshots, reports, and diffs."],
];

const capabilities = [
  ["Observe", "Accessible elements, rendered media, console, network, CSS, cookies, and storage—only when the agent needs them.", false],
  ["Capture", "Browser-pixel MP4 recordings and private PNG artifacts built for frontend QA and PR review.", false],
  ["Reproduce", "Reusable flows, visual comparisons, throttling, offline mode, and exact API mocks.", false],
  ["Contain", "A private Unix socket, no exposed DevTools port, bounded commands, and safe navigation rules.", true],
] as const;

const proofs = [
  { metric: "Tokens", against: "Selenium + Python", value: 64, description: "fewer estimated agent tokens" },
  { metric: "Tokens", against: "Puppeteer", value: 71, description: "fewer estimated agent tokens" },
  { metric: "CPU time", against: "Selenium + Python", value: 56, description: "less CPU time per run" },
  { metric: "CPU time", against: "Puppeteer", value: 66, description: "less CPU time per run" },
] as const;

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
        <div className="hero-beams" aria-hidden="true">
          <BeamsBackground className="hero-beams-static" />
          <PixelBlast
            className="hero-pixel-blast"
            variant="circle"
            pixelSize={5}
            color="#FFB020"
            patternScale={3}
            patternDensity={1.1}
            pixelSizeJitter={0.35}
            enableRipples
            rippleSpeed={0.35}
            rippleThickness={0.1}
            rippleIntensityScale={1.1}
            speed={0.45}
            edgeFade={0.3}
            transparent
          />
        </div>

        <nav className="nav container" aria-label="Main navigation">
          <a className="brand" href="#top" aria-label="Headless home">
            <HeadlessMark className="brand-mark" />
            <span>headless</span>
          </a>
          <div className="nav-links">
            <a href="#workflow">Workflow</a>
            <a href="#capabilities">Capabilities</a>
            <a href="/docs">Docs</a>
            <a href="https://github.com/SarthakWade/headless" className="nav-external">
              GitHub <LinkGlyph kind="external" />
            </a>
            <ThemeToggle />
          </div>
        </nav>

        <div id="top" className="container hero-grid">
          <div className="hero-content">
            <h1>
              Give your agent
              <span> a real browser.</span>
            </h1>
            <p className="hero-copy">
              Headless turns browser QA into a small, inspectable command surface, so an agent can navigate, test, record, and explain without screen coordinates or a brittle script stack.
            </p>
            <div className="hero-actions">
              <a
                href="#workflow"
                className={cn(
                  buttonVariants({ variant: "default", size: "cta" }),
                  "hover:-translate-y-0.5",
                )}
              >
                See the workflow
                <ArrowDownIcon
                  data-icon="inline-end"
                  strokeWidth={1.75}
                  className="size-4 transition-transform duration-200 group-hover/button:translate-y-0.5"
                />
              </a>
              <a
                href="/docs"
                className={buttonVariants({ variant: "quiet", size: "cta" })}
              >
                Read the docs
                <ArrowUpRightIcon
                  data-icon="inline-end"
                  strokeWidth={1.75}
                  className="size-4 transition-transform duration-200 group-hover/button:translate-x-0.5 group-hover/button:-translate-y-0.5"
                />
              </a>
            </div>
          </div>
          <ScanFrame />
        </div>
      </section>

      <section className="benchmark" aria-labelledby="benchmark-title">
        <div className="container benchmark-header">
          <div><div className="section-label">P2 benchmark / 17 Jul 2026</div><h2 id="benchmark-title">Smallest agent surface.<br /><em>Measured, not claimed.</em></h2></div>
          <p>One fresh Linux ARM64 container per case. The same dashboard visit, recording, transition, and final screenshot.</p>
        </div>
        <div className="container benchmark-proof" aria-label="Headless savings vs Selenium and Puppeteer, across tokens and CPU time">
          {proofs.map((proof) => (
            <article key={`${proof.metric}-${proof.against}`}>
              <span>{proof.metric} · vs {proof.against}</span>
              <strong>{proof.value}<small>%</small></strong>
              <p>{proof.description}</p>
            </article>
          ))}
        </div>
        <div className="container benchmark-grid-2">
          <div className="benchmark-chart-panel"><div><span>Agent token footprint / lower is better</span><p>Headless warm = 1×</p></div><BenchmarkChart /></div>
          <div className="benchmark-chart-panel"><div><span>Wall time vs CPU time per run</span><p>The gap is waiting, not computing</p></div><EfficiencyChart /></div>
        </div>
        <div className="container benchmark-table-wrap">
          <table className="benchmark-table">
            <thead><tr><th>Workflow</th><th>Estimated tokens</th><th>Wall time</th><th>CPU time</th><th>Peak memory</th></tr></thead>
            <tbody>{benchmarks.map(([name, variant, tokens, wallTime, cpuTime, memory]) => <tr className={name === "Headless" && variant === "warm" ? "benchmark-highlight" : ""} key={`${name}-${variant}`}><td><b>{name}</b>{variant && <span>{variant}</span>}</td><td>{tokens}</td><td>{wallTime}</td><td>{cpuTime}</td><td>{memory}</td></tr>)}</tbody>
          </table>
        </div>
        <div className="container benchmark-footnote"><p><span className="benchmark-definition"><b>Warm</b> starts with the Headless host and session ready. <b>Cold</b> includes starting both.</span><span>Estimated tokens measure workflow source size, not billed LLM tokens. Point-in-time snapshot; repeat before comparing a change.</span></p><a className="text-link" href="https://github.com/SarthakWade/headless/blob/main/apps/headless/docs/BENCHMARK.md">Read the method <LinkGlyph kind="external" /></a></div>
      </section>

      <section id="workflow" className="section container workflow">
        <div className="section-label">The control loop</div>
        <div className="section-heading"><p>From intent to evidence—</p><h2>without touching the desktop.</h2></div>
        <div className="workflow-layout">
          <div className="command-grid">
            {commands.map(([number, title, description]) => (
              <article className="command-card" key={number}>
                <span>{number}</span><h3>{title}</h3><p>{description}</p><div className="card-rule" />
              </article>
            ))}
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
      </section>

      <section id="capabilities" className="section capabilities">
        <div className="container capability-layout">
          <div className="capability-intro">
            <div className="section-label">Made for real QA</div>
            <h2>When the page breaks,<br />the agent can <em>look closer.</em></h2>
            <p>Deep diagnostics are available on demand, not forced into every interaction.</p>
          </div>
          <div className="capability-list">
            {capabilities.map(([title, description, safe], index) => (
              <article key={title} className={safe ? "capability-row capability-row-safe" : "capability-row"}>
                <span>0{index + 1}</span>
                <div><h3>{title}</h3><p>{description}</p></div>
                <LinkGlyph kind="forward" className="capability-glyph" />
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="section closing">
        <div className="closing-blast" aria-hidden="true">
          <PixelBlast
            className="closing-pixel-blast"
            variant="circle"
            pixelSize={5}
            color="#FFB020"
            patternScale={3}
            patternDensity={1.05}
            pixelSizeJitter={0.3}
            enableRipples
            rippleSpeed={0.35}
            rippleThickness={0.1}
            rippleIntensityScale={1}
            speed={0.4}
            edgeFade={0.45}
            transparent
          />
        </div>
        <div className="container closing-inner">
          <div className="closing-panel">
            <div>
              <div className="section-label">Run it where your agent runs</div>
              <h2>
                Your VM has a browser
                <br />
                now. <em>Use it.</em>
              </h2>
            </div>
            <div className="closing-action">
              <p>
                One CLI protocol. The same commands over MCP. Purpose-built for the last mile of software QA.
              </p>
              <a
                href="https://github.com/SarthakWade/headless/releases"
                className={cn(
                  buttonVariants({ variant: "default", size: "cta" }),
                  "mt-6 hover:-translate-y-0.5",
                )}
              >
                Open Headless
                <ArrowUpRightIcon
                  data-icon="inline-end"
                  strokeWidth={1.75}
                  className="size-4 transition-transform duration-200 group-hover/button:translate-x-0.5 group-hover/button:-translate-y-0.5"
                />
              </a>
            </div>
          </div>
          <p className="closing-credit">
            Headless began as a fork of{" "}
            <a href="https://github.com/antiwork/chromeless">
              antiwork/chromeless <LinkGlyph kind="external" />
            </a>
            . With thanks to Sahil Lavingia for the original foundation.
          </p>
        </div>
      </section>

      <footer className="wordmark-footer">
        <div className="container footer-meta">
          <a className="text-link" href="/docs">DOCUMENTATION <LinkGlyph kind="external" /></a>
        </div>
        <div className="footer-wordmark" aria-label="headless">headless</div>
      </footer>
    </main>
  );
}
