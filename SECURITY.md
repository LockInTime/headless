# Security policy

Headless exists to give an AI agent a browser it _cannot_ misuse. The safety
rules are enforced by the host process, not by prompting, so a vulnerability
here is a vulnerability in the product's core promise. We take reports
seriously.

## Reporting a vulnerability

**Do not open a public issue.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/LockInTime/headless/security/advisories/new).
That opens a private advisory visible only to maintainers.

Please include:

- affected version or commit, and platform (macOS engine or Linux Chromium engine)
- what boundary you crossed, and the commands or page that crossed it
- a minimal reproduction — a fixture page is ideal
- what an attacker gains

We aim to acknowledge within 3 working days and to ship a fix or a documented
mitigation before any public disclosure. Tell us if you intend to publish, and
we will agree a timeline with you.

## What counts as a vulnerability

These are host-enforced contracts. Anything that defeats one is in scope:

| Boundary                        | Expected behaviour                                                                                                                                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **No arbitrary code execution** | There is no JavaScript-evaluation verb and no shell verb. Reaching arbitrary in-page or host execution through the protocol is a vulnerability.                                                                                            |
| **Navigation**                  | HTTP/HTTPS only. `file:`, `javascript:`, `data:`, credential-bearing URLs, and external application schemes must be refused at every layer.                                                                                                |
| **Downloads**                   | Page-initiated downloads are denied. Executables, installers, scripts, libraries, and disk images are blocked by extension.                                                                                                                |
| **Control plane**               | A `0600` Unix socket inside a `0700` per-user directory, with a peer-UID check. There is no TCP listener and no Chromium debug port. Any remote reachability is a vulnerability.                                                           |
| **Artifacts**                   | Bare validated names, `O_EXCL` creation at `0600` inside a `0700` root, never overwritten. Path traversal or reading outside the store is a vulnerability.                                                                                 |
| **Secrets**                     | Cookie and storage _values_ require both `--values` and `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1`. Authorization, cookie, token, and secret headers, plus URL credentials, are always redacted. Flow recordings never contain typed values. |
| **Untrusted content**           | Everything derived from a page is marked `untrustedContent` and is never executed as a command. A page that induces the host to act on its own text is a vulnerability.                                                                    |
| **Sandbox**                     | The Linux host refuses to run as root and never passes `--no-sandbox`. Snap Chromium is rejected before launch.                                                                                                                            |

Prompt injection that merely _persuades an agent_ to do something within these
boundaries is not a host vulnerability — but if page content can escape the
`untrustedContent` marking or reach a privileged path, that is.

## Known limitations (not vulnerabilities)

These are documented design boundaries, not defects:

- **Same-user access.** Any process running as your OS user can reach that
  user's socket, browser profile, and artifacts. Run untrusted agents as
  separate OS users.
- **Shared session state.** Sessions are windows (macOS) or tabs (Linux) over
  one browser profile, so cookies and storage are shared between sessions.
  Per-session isolation is tracked in the roadmap, not implied today.
- **macOS diagnostics are best-effort.** WebKit does not expose Chromium's
  event stream; the macOS QA bridge runs in the page world and is therefore
  observable by the page. Hardening it is tracked as
  [#28](https://github.com/LockInTime/headless/issues/28).
- **Recording scope.** The recorder captures browser frames only — never OS
  chrome, other applications, or audio.
- **Network mocking is Linux-only.** macOS returns `UNSUPPORTED_CAPABILITY`
  rather than partially emulating traffic control.
- **HTTP on macOS.** The ATS exception is limited to `WKWebView` so browser
  pages can use HTTP when required. Native application networking retains the
  default ATS protections.

## Supported versions

Headless is pre-1.x in practice: fixes land on `main` and ship in the next
tagged release. There is no long-term support branch yet.

## Hardening guidance for operators

- Run agents as a dedicated OS user, not your own account.
- Leave `HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS` unset unless you are actively
  debugging, and never in a shared session.
- Keep the stdio MCP server local, or tunnel it over SSH. Do not bridge it to
  a network listener.
- Treat every artifact, report, and console line as potentially sensitive
  page content.
