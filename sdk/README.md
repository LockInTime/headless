# Headless SDK contract

`protocol-schema.json` is the checked-in SDK contract emitted by the Swift
implementation:

```sh
swift run --package-path apps/headless headless schema > sdk/protocol-schema.json
```

The protocol suite compares this file byte-for-byte with `headless schema` and
also decodes it back to the Swift value. Do not edit the JSON by hand.

## Compatibility

The wire protocol and product versions are independent. SDKs support the exact
wire version in their bundled schema. An older client sends only commands and
parameters present in that schema. A newer client must reject an older host
before decoding a result for an unsupported wire version, and must use the
host capability document before issuing an engine-specific command.

Compatible additions retain the current wire version. Removing or changing a
field, command, constraint, error meaning, framing rule, or security guarantee
requires a protocol-version change and migration notes. The schema format has
its own integer version so generators can reject unknown metadata.

## Transport and cancellation

SDKs use the existing private, same-user Unix socket. They do not add TCP,
remote control, a Chromium debug port, or arbitrary JavaScript. Closing a
client connection before a request is written cancels it. Closing after send
does not roll back a browser operation, so the SDK must report an unknown
outcome and require a fresh inspection.

An SDK may terminate and reap only a host process that it launched and owns.
It must not stop an already-running shared host during cancellation, timeout,
or client shutdown.

Use `headless start --background --supervised` for an owned host. The command
fails if a shared host already exists, prints the normal startup response, and
then remains attached to the host. The SDK keeps the child standard-input pipe
open for the ownership lifetime. Closing the pipe makes the host stop and lets
the launcher be awaited. A plain `headless start` remains detached and shared.

## Release policy

Generated SDKs pin a schema digest and wire version. Schema and client changes
are reviewed together. SDK packages are versioned independently from the
Headless product while declaring their supported wire versions. Before 1.0,
deprecations remain for at least one minor SDK release; after 1.0, removals
require a major SDK release. Security reports use the repository process in
`SECURITY.md` and must not include credentials, cookies, or private artifacts.
