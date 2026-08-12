@AGENTS.md

Claude Code specific notes:

- The browser-use skill is auto-discovered at
  `.claude/skills/headless-computer-use` and symlinked to the canonical
  `.agents/skills/headless-computer-use` source.
- `pnpm test:e2e:mac` opens real windows and mutates `com.headless.app`
  user defaults — don't run it in a background/headless session.
