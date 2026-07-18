# Design: Computer use comparison scores in README

## Goal

Add a scannable comparison to `README.md` that scores three agent browser
paths on qualitative 1–5 dimensions, and separately cites the existing
measured agent-surface numbers from `apps/headless/docs/BENCHMARK.md`.

## Baselines

1. **Coordinate computer use** on a regular browser window (screenshot +
   click coordinates; Claude/OpenAI-style desktop/browser CU).
2. **Scripted automation** (Playwright / Puppeteer / Selenium).
3. **Headless** (this project: semantic inspect + role/name/`@ref` actions).

## Placement

Insert a **Computer use comparison** section in `README.md` immediately after
the opening platform blurb and before **Agent workflow**.

## Framing

- Scores are qualitative capability judgments for agent browser work.
- They are not lab benchmarks and must not be presented as such.
- Measured workflow surface stays in a short callout that links to
  `apps/headless/docs/BENCHMARK.md` and reuses existing point-in-time numbers
  only (no new benchmark run required for this change).

## Score table (1–5)

| Dimension | Coordinate CU (regular browser) | Scripted (PW / Puppeteer / Selenium) | Headless |
| --- | :---: | :---: | :---: |
| Targeting precision | 2 | 4 | 5 |
| Safety / blast radius | 2 | 3 | 5 |
| Evidence (shots, video, QA) | 3 | 3 | 5 |
| Agent surface (tokens / glue) | 2 | 3 | 5 |
| Setup friction | 3 | 3 | 4 |
| Platform coverage (host OS) | 5 | 5 | 4 |
| Desktop / OS reach | 5 | 1 | 1 |

`Platform coverage` is where the tool runs as a host: Headless scores 4 because
it supports macOS and Linux (including Ubuntu and common CI/test distros) but
not Windows. `Desktop / OS reach` remains separate — whether the agent can
drive the whole desktop vs browser-only.

### Rationale (keep short under the table)

- **Coordinate CU** — strongest desktop/OS reach; weaker web targeting
  (pixel drift), higher screenshot/prompt cost, broader blast radius;
  Windows/macOS/Linux hosts.
- **Scripted** — reliable selectors and driver APIs; more agent glue; evidence
  and security posture usually bolted on; Windows/macOS/Linux hosts.
- **Headless** — semantic targeting, private socket + allowlisted commands,
  built-in record/screenshot/diagnostics; browser-only (no desktop);
  macOS + Linux only (Windows unsupported).

## Measured callout

Reuse BENCHMARK.md current snapshot (Docker ARM64, 17 July 2026,
point-in-time):

- Headless warm: **147** estimated tokens
- Selenium: **410**
- Puppeteer: **499**

Link to the full method and limits. Do not invent new timings.

## Out of scope

- Re-running `benchmark.sh`
- Changing product behavior, CLI, or BENCHMARK.md methodology
- Claiming Headless wins overall (desktop reach stays lowest)

## Implementation

Edit `README.md` only (plus this design doc). No code or test changes.
