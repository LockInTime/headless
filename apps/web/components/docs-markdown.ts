import cursorConfig from "../../../.cursor/mcp.json";

export const pageMarkdown = `# Headless documentation

Headless gives an agent a persistent browser through a small, safe CLI. Use it to test a page, capture evidence, and inspect a failure.

## First run

Start the host, create a session, then visit the app. The session stays isolated until you close it.

\`\`\`sh
headless start
headless session create qa
headless --session qa visit localhost:3000/designers/dashboard
headless --session qa inspect --context summary --task "click Continue"
\`\`\`

On macOS, agent startup leaves your current app in front. Use \`headless config set startup-presentation foreground\` to make the old foreground behavior persistent, or set it to \`background\` to restore the built-in default. Inspect it with \`headless config get startup-presentation\`. The \`headless start --foreground\` and \`--background\` flags override the setting for one new host; they do not reorder a running host.

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

Start with \`inspect --context summary --task "..."\`. On a large page, request \`--context outline\`, choose a returned region such as \`@r4\`, then ask only for \`--context text --within @r4\` or \`--context actions --within @r4\`. Use \`--limit\`, \`--budget\`, and \`--depth\` to cap responses. Each result reports omitted content and conservative estimated-token statistics. Use \`inspect --context full --text\` only when the broader raw snapshot is required.

## Scrollable page evidence

\`\`\`sh
headless --session qa screenshot --every-viewport --output dashboard-scroll
headless --session qa screenshot --by-section --format jpg --output dashboard-sections
\`\`\`

Use viewport screenshots for up to 80 100vh scroll stops, always including the final bottom position; bounded results report \`truncated\` and \`totalPoints\`. Series capture restores the original scroll position and creates numbered PNG or JPG artifacts from the prefix. PDF requires \`--full-page\`; macOS image screenshots can also use clipboard output.

## Safety

Headless uses a private Unix socket, not a public DevTools port. Only HTTP(S) navigation is allowed. Diagnostic secrets are redacted.

## Platforms

- Linux: use the supplied Docker runtime or native Chromium. Ubuntu Snap Chromium is not supported for repeated navigation.
- macOS: build with Xcode Command Line Tools and use the visible WKWebView host through the same CLI.`;

export const cursorMcpConfig = JSON.stringify(cursorConfig, null, 2);
