# Where headless goes next

This is the plan for the next few months, written so anyone on the team can follow it.
It records what we decided, why we decided it, and the order we work in.

## What headless is

Headless gives AI agents a real browser through a small command set:

```
headless click --role button --name Continue
```

No screenshots. No pixel coordinates. No Playwright scripts.
The agent asks for things by meaning and gets back bounded, inspectable results.

Two engines already exist behind one contract:

```
            one protocol (JSON v0.5 over a private Unix socket)
                        |
        +---------------+----------------+
        |                                |
  macOS host                       Linux host
  WKWebView app                    sandboxed Chromium
  (ships with the OS)              driven over CDP fd 3/4
```

The shared code lives in `apps/headless/Sources/HeadlessProtocol/`.
Each engine only implements what makes it different. That split is the whole reason
this plan works, so protect it.

## The decision: no rewrite

We looked at rewriting the core in Rust or Go to get Windows and "better performance".
We are not doing that. Here is the honest reasoning.

Performance is not a reason. The benchmark numbers on our own site show agent token
use is dominated by the browser, not by our control plane. Rewriting the socket layer
in Rust would change nothing a user can measure.

Reliability is not a reason either. About ten thousand lines of Swift already pass the
protocol suite, the runtime suite, and E2E tests on two platforms. A rewrite resets
all of that to zero for months.

Windows was the one real argument for a rewrite, because Swift's Windows support is
weak. But Edge ships on every Windows machine and speaks the same CDP protocol our
Linux host already uses. So Windows becomes a third engine adapter, not a rewrite.
We still test the ground truth first, with a spike (step 1 below). If the spike fails,
we port only the shared core to Rust, never the whole product.

## The plan

```
 step 0          step 1           step 2                step 3            step 4
 ship the        Windows          add the adapter       make each OS      hand off
 pending work    spike            OR do the port        feel native       features
 --------------  ---------------  --------------------  ----------------  ----------
 release v1.1.0  compile the      spike passes:         winget/MSI        C7 review (#35)
 close docs      shared core      keep Swift, add       install paths     G-series ideas (#54)
 debt (#53)      on Swift for     a Windows engine      config paths      assigned to
                 Windows in a     adapter               code signing      SarthakWade
                 throwaway test   spike fails:
                 branch           ADR, then port
                                  only HostCore to
                                  Rust
```

### Step 0: release and docs

Everything since v1.0.2 is unreleased. That is risk piling up, so this goes first.

- Cut the release (#45)
- Close the docs debt (#53): @eN contract, session model, stale paths

### Step 1: the Windows spike

One week, throwaway code, no commits to main. Try to build
`Sources/HeadlessProtocol/` with the Swift toolchain on Windows.

Two outcomes, both fine:

```
   spike builds?            outcome
  ---------------  --------------------------------------
     yes           keep Swift. Write the third adapter.
     no            write the ADR, port only the shared
                   core to Rust. Protocol spec, runtime
                   JS, and all tests stay as they are.
```

Either way we win, because the protocol and the test suites survive untouched.

### Step 2: the adapter or the port

If Swift survived the spike, we add a Windows engine adapter. Edge is Chromium,
so most of `LinuxHost/BrowserProcess.swift` and `CDP.swift` carries over. Only
process spawning and paths differ.

If the spike failed, we write the architecture decision entry first, then port
the shared core to Rust. Scope stays tight: dispatcher, CLI parser, artifacts,
transport. Nothing else moves.

### Step 3: native packaging

Code gets a product onto a machine. Packaging makes it feel like it belongs there.

| | macOS | Linux | Windows |
|---|---|---|---|
| browser | WKWebView, built in | system Chromium | Edge, built in |
| install | brew cask | curl script | winget / MSI |
| config | ~/Library | XDG dirs | %APPDATA% |
| signing | notarized | SHA256SUMS | Authenticode |

Most of this table is packaging work, not engineering. That is the point.

### Step 4: features (SarthakWade)

Once steps 0 to 3 land, feature work starts:

- hover, drag, select, isolation from the design review (#35)
- committed ideas from the tracking issue (#54)

## Rules that do not bend

These live in AGENTS.md and they hold during every step above:

1. no arbitrary JavaScript verb, no TCP listener, no debug port
2. fail closed on anything unknown
3. artifacts never overwrite and never escape their store
4. flows never record fill values
5. everything bounded reports its truncation

Any change to the agent facing contract needs an entry in
`docs/roadmap/architecture-decisions.md` before the code lands.

## What we deliberately skipped

- bun instead of pnpm: churn, no gain, CI already gates on pnpm
- cosmetic folder renames: if the spike leads to a Rust core, those files
  get deleted anyway
- the website (#47 to #51): deprioritized until the core plan lands
