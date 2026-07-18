# Implementation plan: rename the project to headless and scope the Ubuntu Chromium report

## Objective

Rename every working-tree reference from the former project name to `headless`, including both capitalization forms, paths, package metadata, application bundle names, executable names, user-facing text, generated artifact names, identifiers, and examples.

Also address the reported Ubuntu Snap Chromium behavior without inventing an implementation unsupported by the repository. The report says that an initial local page can work while later navigation or reload freezes the browser control connection, and that a Docker environment with a bundled Debian Chromium runtime passes the full P2 flow. At initial inspection, the repository could not reproduce or fix that control-path behavior because it did not contain Chromium control code or the P2 flow, so the initial rationale was to state the platform boundary accurately and keep runtime work with the repository that owns those components. The implemented runtime fix uses bundled Debian Chromium instead of Ubuntu Snap Chromium and validates the complete P2 flow in Docker.

## Repository findings

- The tracked tree contains one application, a native macOS 13 or newer Cocoa application implemented as a single Swift file. It embeds `WKWebView`, which uses WebKit. It does not launch or connect to Chromium.
- The browser UI, navigation delegates, reload behavior, snapshots, and command-line parsing all lived in the former app directory's `main.swift`.
- The native build was driven by the former app directory's `build.sh`. It invoked `swiftc`, built a macOS `.app` bundle, ran `codesign`, and optionally used Apple's passkey entitlement.
- The pnpm workspace has no JavaScript or TypeScript implementation dependencies. Its package scripts only dispatch to the native macOS build script.
- There are no automated tests, test scripts, fixtures, CI workflows, or P2 definitions in the repository.
- There is no `Dockerfile`, Compose file, container script, Chromium binary or dependency, Chromium launcher, Chrome DevTools Protocol client, MCP server or client, browser-control socket, Linux application code, or Snap integration.
- The single commit in the repository history contains the same macOS WebKit application and does not reveal a removed Chromium, MCP, Docker, or P2 implementation.
- The configured Git remote already uses the `headless` repository name, so no remote configuration change is needed or authorized.
- The current inspection environment is Ubuntu Linux on ARM64 and has neither `pnpm` nor Swift installed. The macOS application cannot be built or run in this environment because it requires the macOS Cocoa and WebKit frameworks, Xcode Command Line Tools, `iconutil`, and `codesign`.

## Planned file and path changes

### 1. Move the native application to the new project path

- Rename the former app directory to `apps/headless/` as one move so that history remains easy to follow.
- Rename the former entitlement file to `apps/headless/headless.entitlements`.
- Keep the source layout otherwise unchanged. In particular, retain `apps/headless/main.swift`, `apps/headless/build.sh`, and `apps/headless/tools/make-icon.swift` rather than introducing a new build system.

### 2. Update workspace metadata and generated-file rules

- In `package.json`, change the workspace package name to `headless` and change all three pnpm filters from the legacy package scope to `@headless/app`.
- In `apps/headless/package.json`, change the package name to `@headless/app` and make the start script open `Headless.app`.
- Regenerate `pnpm-lock.yaml` with the repository-pinned pnpm 9.15.0 after the directory move. Confirm that its importer is `apps/headless` and that no legacy importer remains. Since there are no dependencies, do not add packages merely to force a lockfile update.
- In `.gitignore`, change the native artifact comment and all paths to `apps/headless/Headless.app/`, `apps/headless/Headless.icns`, and `apps/headless/build/`.

### 3. Rename the macOS product and all application-visible references

- In `apps/headless/build.sh`:
  - Build `Headless.app`, `Headless.icns`, and `Headless.app/Contents/MacOS/Headless`.
  - Update the icon copy destination and all generated `Info.plist` references to `Headless`.
  - Change `CFBundleIdentifier` from the legacy bundle identifier to `com.headless.app` so the bundle metadata no longer retains the former project name.
  - Change the copyright text, provisioning-profile example, entitlement path, comments, status output, and executable example to the new name.
  - Preserve the Apple entitlement key `com.apple.developer.web-browser.public-key-credential`. It is an Apple-defined capability identifier, not project branding.
- In `apps/headless/main.swift`:
  - Change the file header, CLI examples, help banner, usage command, diagnostics, start-page title and heading, default window title, screenshot filename prefix, menu item labels, and help label to the corresponding `headless` or `Headless` form.
  - Change the window frame autosave key from the legacy product-specific key to `HeadlessMain` because it contains the former product name. Keep the brand-neutral `LastURL` preference key unchanged.
  - Do not rename generic browser concepts such as the `Chrome` section comment or wording such as "no chrome." Those describe browser chrome and are not references to the old project name.
  - Do not alter navigation, reload, WebKit delegate, passkey, snapshot, URL parsing, or window behavior as part of the rename.
- In `apps/headless/tools/make-icon.swift`, change the branded file comment to `Headless`. Keep the generic icon-design comment about a frame with no chrome.
- The content of `apps/headless/headless.entitlements` does not currently contain a project-name reference. Preserve its Apple capability and explanatory comments unless validation exposes a naming reference introduced by the move.

### 4. Rewrite the README and document the platform boundary

- In `README.md`, change the title, application heading, workspace path, package examples, output bundle path, and layout example to `headless`, `Headless`, `apps/headless`, and `Headless.app` as appropriate.
- Keep the existing macOS setup and build instructions, but state explicitly that this repository currently provides a native macOS `WKWebView` shell and does not provide a Linux browser-control service.
- Add a short Ubuntu Chromium limitation section that records only what is known:
  - Ubuntu's Snap-packaged Chromium has been reported to load an initial local page but freeze the external control connection on later navigation or reload.
  - A Docker environment with bundled Debian Chromium completed the full P2 flow.
  - At initial inspection, neither observation was reproducible because the relevant Chromium control layer, Docker runtime, and P2 test suite were absent.
  - The implemented runtime fix uses bundled Debian Chromium; it does not claim that the macOS application itself fixes or validates the Linux flow.
- The initial plan directed runtime remediation to the repository owning the control layer. The implemented work uses bundled, versioned Debian Chromium instead of Ubuntu's Snap package and accepts the fix through the full P2 flow covering initial local load, a second navigation, reload, and continued control-channel responsiveness.
- The initial scope avoided speculative container, protocol, Chromium, Linux launcher, control-connection, or placeholder P2 components that could not be derived from the repository. The merged implementation supplies the concrete runtime and validation components needed for the bundled Debian Chromium fix.

### 5. Remove the final legacy-name references from the planning record

- This plan initially named the former paths and values so the rename could be implemented exactly. After the code and documentation changes are complete, revise `.hermes/plans/rename-to-headless-and-scope-ubuntu-chromium.md` to replace literal former-name examples with neutral wording such as "former project name," "former app directory," "legacy package scope," and "legacy environment variable."
- Keep the destination paths, validation commands, repository findings, Ubuntu limitation, and validation rationale intact. This final cleanup allows the whole working tree, including `.hermes`, to satisfy the requirement that no former project-name reference remains.
- Do not change `pnpm-workspace.yaml` or `packages/.gitkeep`; their current content is brand-neutral. The complete intended tracked-file scope is the two path renames plus updates to `.gitignore`, `README.md`, `package.json`, `pnpm-lock.yaml`, `apps/headless/build.sh`, `apps/headless/package.json`, `apps/headless/main.swift`, `apps/headless/tools/make-icon.swift`, and this plan.

## Tests and validation

### Static validation available on any platform

1. From the repository root, search both file content and file names for the former project name. Supply the actual former name to these placeholders when running the checks so this plan does not retain the literal search term after its final cleanup:

   ```sh
   rg -n -i '<former-project-name>' --hidden -g '!.git/**' .
   find . -path './.git' -prune -o -iname '*<former-project-name>*' -print
   ```

   Both commands must produce no output after the planning record cleanup.

2. Search for stale package, bundle, and path forms separately, then inspect every hit rather than relying only on the general search:

   ```sh
   rg -n '<legacy-package-scope>|<legacy-bundle-identifier>|<former-app-bundle>|<former-app-directory>' --hidden -g '!.git/**' .
   ```

   This command must produce no output.

3. Confirm the renamed workspace is discoverable and the lockfile is synchronized with the pinned package manager:

   ```sh
   corepack pnpm install --lockfile-only --frozen-lockfile=false
   corepack pnpm --filter @headless/app exec pwd
   plan_lock_copy="$(mktemp)"
   cp pnpm-lock.yaml "$plan_lock_copy"
   corepack pnpm install --lockfile-only --frozen-lockfile=false
   cmp -s pnpm-lock.yaml "$plan_lock_copy"
   rm "$plan_lock_copy"
   ```

   The filter command must resolve to `apps/headless`. The comparison must show that a second lockfile calculation produces no further change. The temporary file is an exact copy made only for this comparison and is removed immediately afterward.

4. Parse both package manifests and inspect the intended scripts:

   ```sh
   node -e 'for (const f of ["package.json", "apps/headless/package.json"]) { const p = require("./" + f); console.log(f, p.name, p.scripts) }'
   ```

   The output must show `headless`, `@headless/app`, filters for `@headless/app`, and `open Headless.app`.

5. Run repository hygiene checks:

   ```sh
   git diff --check
   git status --short
   ```

   Review the status to confirm that the only changes are the two renames, the planned content updates, the lockfile importer update, and this plan update. There must be no generated `.app`, `.icns`, iconset, or `build/` artifact and no unrelated file change.

### macOS build and product validation

Run these checks on macOS 13 or newer with Xcode Command Line Tools and the repository-pinned pnpm version. They cannot run on the current Ubuntu host.

1. Build through the public workspace entry point:

   ```sh
   corepack pnpm build
   ```

   Confirm that it creates `apps/headless/Headless.app` and does not create any former-name artifact.

2. Validate the generated property list, executable, and signature:

   ```sh
   plutil -lint apps/headless/Headless.app/Contents/Info.plist
   plutil -p apps/headless/Headless.app/Contents/Info.plist
   test -x apps/headless/Headless.app/Contents/MacOS/Headless
   codesign --verify --deep --strict apps/headless/Headless.app
   ```

   Inspect the property-list output for `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable`, and `CFBundleIconFile` equal to `Headless`, and for `CFBundleIdentifier` equal to `com.headless.app`.

3. Validate the CLI surface:

   ```sh
   apps/headless/Headless.app/Contents/MacOS/Headless --help
   ```

   Confirm the banner, usage command, and examples use the new name. Run an unknown-option case and a deliberately failing snapshot load to confirm diagnostic prefixes also use the new name.

4. Perform a macOS smoke test of unchanged application behavior:

  - Launch `Headless.app` and confirm the start page, window title, About, Hide, Quit, and Help labels use the new name.
  - Open a local HTML file, navigate to a second local or HTTP page, reload, hard reload, go back, and go forward.
  - Save a snapshot and confirm its default Desktop filename starts with `headless `.
  - Close and relaunch the application and confirm the window frame and last HTTP URL behavior still work under the renamed build.
  - If signing credentials and an Apple provisioning profile are available, run the optional signed build with the renamed entitlement file. Otherwise, verify the default ad hoc signing path only and record the signed path as not run.

This smoke test protects the existing WebKit application from rename regressions. It does not validate the reported Ubuntu Chromium control freeze because the macOS application has no such control channel.

### Ubuntu Chromium and P2 validation status

- At initial inspection, no Ubuntu Snap Chromium reproduction or Docker Chromium P2 test could be run from this repository, so those validations were deferred rather than marked passed or failed.
- The implemented runtime fix uses bundled Debian Chromium, rejects the unreliable Ubuntu Snap runtime, and runs the complete P2 sequence in Docker.
- Acceptance evidence identifies the Chromium build and container image used, then shows the complete P2 sequence continuing through the first local load, subsequent navigation, reload, and a final control command. That requirement preserves the original validation rationale.

## Risks and mitigations

- **macOS identity changes:** Changing `CFBundleIdentifier` makes macOS treat the renamed bundle as a different application. Existing preferences, privacy grants, signing profiles, Keychain associations, and window-frame state tied to the legacy identifier may not carry over. Accept the reset as part of a complete rename, document it if users rely on prior state, and validate both ad hoc and provisioned signing paths when credentials exist.
- **Provisioning mismatch:** Existing Apple profiles may be bound to the legacy bundle identifier. Do not weaken or remove signing checks to make them pass. Obtain a profile for `com.headless.app` before claiming the passkey-enabled build works.
- **stale build artifacts:** Ignored former-name `.app` or `.icns` files can survive locally and confuse manual testing even after tracked paths are renamed. Inspect the application directory before testing and remove only explicitly identified generated artifacts. Do not use a broad destructive cleanup command.
- **workspace drift:** Manually editing only the lockfile importer can hide a mismatch with pnpm workspace discovery. Regenerate with pnpm 9.15.0 and prove a second regeneration is idempotent.
- **over-broad replacement:** A blind case-insensitive replacement could corrupt Apple's `web-browser` entitlement, generic mentions of browser chrome, or unrelated prose. Limit replacements to the two former project-name case forms and review every diff hunk.
- **Linux claims:** Preserve the distinction between the reported Snap freeze and the merged Docker P2 evidence. The implemented runtime fix is specifically the bundled Debian Chromium path.
- **scope expansion:** Adding a Linux browser-control stack merely to answer the report would require architecture, dependency, security, lifecycle, and test decisions with no local foundation. Keep that implementation in the owning repository and limit this repository to accurate documentation.
- **test coverage gap:** There is no automated test harness for the Swift application. Use static scans plus the macOS build, CLI, bundle, signing, and GUI smoke checks. Adding a new test framework is not justified for a branding-only change.

## Completion criteria

- The working tree contains no file, path, package scope, bundle field, executable, artifact name, UI label, CLI output, example, or planning-record reference using the former project name in either requested case form.
- `apps/headless/` is the only application directory, and the root pnpm scripts resolve `@headless/app` successfully.
- A macOS build produces a valid, signed `Headless.app` whose executable, icon, property-list identity, CLI, menus, start page, and snapshot filenames use the new name.
- Existing WebKit navigation, reload, history, snapshot, URL persistence, and window behavior pass the macOS smoke test.
- `README.md` accurately distinguishes the repository's macOS WebKit scope from the absent Ubuntu Chromium control stack and records the reported Snap and Docker observations without claiming local verification.
- The Ubuntu control-connection remediation uses bundled Debian Chromium, and the full P2 run validates the runtime and control implementation without relying on Ubuntu Snap Chromium.
