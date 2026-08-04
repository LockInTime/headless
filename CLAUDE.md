@AGENTS.md

Claude Code specific notes:

- The repository's browser-use skill lives at
  `.agents/skills/headless-computer-use/SKILL.md` (not auto-discovered);
  read it before driving Headless as a tool.
- `pnpm test:e2e:mac` opens real windows and mutates `com.headless.app`
  user defaults — don't run it in a background/headless session.
