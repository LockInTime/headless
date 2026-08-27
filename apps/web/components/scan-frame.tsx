const elements = [
  { ref: "@e3", role: "link", name: "Documentation", accent: false },
  { ref: "@e7", role: "textbox", name: "Project URL", accent: false },
  { ref: "@e8", role: "button", name: "Run audit", accent: true },
] as const;

/** Repository-owned demo of the semantic inspect-and-act contract. */
export function ScanFrame() {
  return (
    <div
      className="scan-frame"
      role="img"
      aria-label="Headless inspects a local application and returns semantic references for a link, textbox, and button"
    >
      <div className="scan-frame-head">
        <span className="scan-dot" />
        <span className="scan-dot" />
        <span className="scan-dot" />
        <p>localhost:3000</p>
        <span className="scan-head-status">
          <span className="scan-head-pulse" />
          private session
        </span>
      </div>

      <div className="scan-surface">
        <div className="scan-app-nav">
          <span className="scan-app-mark">H</span>
          <span>Workspace</span>
          <span className="scan-app-nav-link">Documentation</span>
        </div>
        <div className="scan-app-content">
          <span className="scan-app-kicker">New audit</span>
          <strong>Check a page with your agent.</strong>
          <p>
            Enter a local URL. Headless keeps the browser control plane private.
          </p>
          <div className="scan-app-form">
            <span>http://localhost:3000/dashboard</span>
            <b>Run audit</b>
          </div>
        </div>
        <div className="scan-grid" aria-hidden="true" />
        <div className="scan-elements" aria-hidden="true">
          {elements.map((element) => (
            <div
              className={`scan-element${element.accent ? " scan-element-action" : ""}`}
              key={element.ref}
            >
              <span>{element.ref}</span>
              <i>{element.role}</i>
              <b>{element.name}</b>
            </div>
          ))}
        </div>
      </div>

      <div className="scan-terminal">
        <div className="scan-terminal-row">
          <span className="scan-terminal-prompt">$</span>
          <code>
            headless inspect --context actions --task &quot;run an audit&quot;
          </code>
        </div>
        <div className="scan-terminal-row scan-terminal-result">
          <span className="scan-terminal-prompt">&gt;</span>
          <code>8 elements · semantic refs ready</code>
        </div>
      </div>
    </div>
  );
}
