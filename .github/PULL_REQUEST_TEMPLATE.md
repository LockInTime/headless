<!--
Thanks for contributing. Keep this template short and honest — delete
sections that genuinely do not apply, rather than ticking boxes you did not
verify.
-->

## What this changes

<!-- One paragraph. What behaviour is different after this merges? -->

Closes #

## Why

<!-- Link the backlog item (§A1, §B3, …) or the decision that motivates it. -->

## How it was verified

<!-- Name what you actually ran. "CI will tell us" is not verification. -->

- [ ] `pnpm test`
- [ ] `pnpm test:runtime`
- [ ] `pnpm test:e2e:linux` — required if this touches a host, transport, agent runtime JS, or artifacts
- [ ] `pnpm test:e2e:mac` — or the `macos-e2e` label, required if this touches `main.swift`, `Host/`, or capture code
- [ ] New or updated tests cover the change

## Contracts

<!--
These are host-enforced and must survive. Confirm the ones your change comes
near; delete the rest. See docs/roadmap/what-is-excellent.md
-->

- [ ] No arbitrary-JS verb, no TCP listener, no debug port introduced
- [ ] Navigation stays HTTP/HTTPS only; downloads stay denied
- [ ] Artifacts stay bare-named, `O_EXCL`, `0600`, non-overwriting
- [ ] Validation still fails closed (unknown params rejected, capability errors explicit)
- [ ] Bounded output still reports truncation (`omitted`, `truncated`, `contextStats`)
- [ ] Page-derived text stays marked `untrustedContent`; no typed values recorded in flows
- [ ] Behaviour is identical on both engines, or the difference is an explicit `UNSUPPORTED_CAPABILITY`

## Housekeeping

- [ ] Backlog item checked off in `docs/roadmap/improvements-backlog.md`
- [ ] Architecture-decision entry added, if this changes a settled decision or the agent-facing contract
- [ ] A new protocol command was added to *both* hosts, the validator, the CLI, help text, and `capabilities`
- [ ] Docs updated — phase contract, README, and every duplicated copy on the site
- [ ] No committed media outside regenerated `docs/qa/evidence/` (checksums updated if so)
