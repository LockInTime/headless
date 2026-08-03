export const pageMarkdown = `# Headless documentation

Headless gives an agent a persistent browser through a small, safe CLI. Use it to test a page, capture evidence, and inspect a failure.

## First run

Start the host, create a session, then visit the app. The session stays isolated until you close it.

\`\`\`sh
headless start
headless session create qa
headless --session qa visit localhost:3000/designers/dashboard
headless --session qa inspect --context actions --task "click Continue"
\`\`\`

## QA workflow

Record the path you need, then stop and create a report.

\`\`\`sh
headless --session qa record start --fps 10 --format mp4
headless --session qa click --role button --name Continue
headless --session qa wait --url /next --settled
headless --session qa record stop --output dashboard-flow.mp4
headless --session qa report create --output pr-report.json
\`\`\`

## Command groups

- Navigation: visit, back, reload, wait
- Interaction: inspect, click, fill, press, scroll
- Evidence: screenshot, record, visual compare, report
- Diagnostics: console, network, styles, cookies, storage

## Context pruning

Use \`inspect --context actions --task "search open ai"\` when the agent needs a clean action map. It returns visible buttons, links, fields, selects, upload inputs, menus, and tabs first, ranked for the current task. Use \`inspect --context full\` only when the broader page snapshot is needed.

## Scrollable page evidence

\`\`\`sh
headless --session qa screenshot --every-viewport --output dashboard-scroll
headless --session qa screenshot --by-section --format jpg --output dashboard-sections
\`\`\`

Use viewport screenshots for every 100vh scroll stop, and section screenshots for headings, sections, and regions. Series commands create numbered PNG or JPG artifacts from the prefix. Single screenshots also support JPG/JPEG, PDF, and macOS image clipboard output.

## Safety

Headless uses a private Unix socket, not a public DevTools port. Only HTTP(S) navigation is allowed. Diagnostic secrets are redacted.

## Platforms

- Linux: use the supplied Docker runtime or native Chromium. Ubuntu Snap Chromium is not supported for repeated navigation.
- macOS: build with Xcode Command Line Tools and use the visible WKWebView host through the same CLI.`;

export const cursorMcpConfig = `{
  "mcpServers": {
    "headless": {
      "command": "ssh",
      "args": ["hermes-vm", "headless-mcp"]
    }
  }
}`;
