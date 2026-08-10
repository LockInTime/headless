// headless — the browser that isn't there.
//
// A single-file macOS browser with zero chrome: no tabs, no toolbar, no
// address bar — just the page, in a bare rounded window. Built on WKWebView
// (the Safari engine). Made for clean screenshots and fullscreen video.
//
//   ⌘L  search / open url        ⇧⌘S  snapshot page → Desktop
//   ⌘R  reload                   ⌘P   pin window on top
//   ⌘[ ⌘]  back / forward        ⌃⌘F  fullscreen
//   ⌘= ⌘- ⌘0  zoom               ⌘drag  move the window
//
// CLI screenshot mode:
//   headless https://example.com --snap out.png --size 1440x900 --wait 2

import Cocoa
import HeadlessProtocol
import Security
import WebKit

// MARK: - Passkey capability

// WKWebView performs WebAuthn (passkeys via iCloud Keychain / Touch ID) only for
// apps signed with Apple's restricted web-browser.public-key-credential
// entitlement, which needs an Apple-issued provisioning profile — macOS kills
// ad-hoc builds that claim it. So: if this build carries the entitlement,
// passkeys just work; if not, hide the WebAuthn API so sites feature-detect the
// absence and offer their fallback sign-in (password, phone prompt) instead of
// a passkey ceremony that is guaranteed to fail. See README for enabling it.
let hasPasskeyEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
}()

/// The CLI starts the app in this mode. It must never inherit a manually
/// browsed page (including a local file) into the agent's default session.
let isAgentHost = ProcessInfo.processInfo.environment["HEADLESS_AGENT_HOST"] == "1"

// MARK: - URL smarts

func smartURL(_ input: String) -> URL? {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if t.hasPrefix("/") || t.hasPrefix("~") {
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    }
    if t.contains("://") { return URL(string: t) }
    let lower = t.lowercased()
    if isLocalDevelopmentAddress(lower) { return URL(string: "http://" + t) }
    if !t.contains(" "), t.contains(".") { return URL(string: "https://" + t) }
    let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
    return URL(string: "https://www.google.com/search?q=" + q)
}

// MARK: - Launch options

struct SnapJob { let path: String; let wait: TimeInterval }

struct LaunchOptions {
    var url: URL? = nil
    var snap: SnapJob? = nil
    var size: NSSize? = nil
}

func parseLaunchOptions() -> LaunchOptions {
    var opts = LaunchOptions()
    var snapPath: String? = nil
    var wait: TimeInterval = 1.0
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--help", "-h":
            print("""
            headless — the browser that isn't there

            usage: headless [url] [options]
              --snap <path>     load the page, save a PNG of it, and quit
              --size <WxH>      window size in points (e.g. 1440x900)
              --wait <seconds>  extra settle time before --snap (default 1.0)

            examples:
              headless youtube.com
              headless localhost:3000 --snap shot.png --size 1280x800
            """)
            exit(0)
        case "--snap":
            i += 1
            if i < args.count { snapPath = args[i] }
        case "--size":
            i += 1
            if i < args.count {
                let parts = args[i].lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { opts.size = NSSize(width: parts[0], height: parts[1]) }
            }
        case "--wait":
            i += 1
            if i < args.count { wait = Double(args[i]) ?? 1.0 }
        default:
            if a.hasPrefix("-") {
                fputs("headless: ignoring unknown option \(a)\n", stderr)
            } else if let u = smartURL(a) {
                opts.url = u
            }
        }
        i += 1
    }
    if let p = snapPath {
        let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        opts.snap = SnapJob(path: abs, wait: wait)
    }
    return opts
}

let launchOptions = parseLaunchOptions()

// MARK: - Start page

let startPageHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><title>headless</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { background: #0a0a0e; color: #e8e8ee; font: 15px/1.6 -apple-system, system-ui;
         display: flex; align-items: center; justify-content: center;
         -webkit-user-select: none; cursor: default; }
  main { text-align: center; max-width: 680px; padding: 48px; animation: in .6s ease-out; }
  @keyframes in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
  h1 { font-size: 46px; font-weight: 650; letter-spacing: -.02em; margin: 0 0 6px; color: #fff; }
  p.tag { color: #85858f; margin: 0 0 46px; font-size: 16px; }
  .keys { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
          justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 48px; color: #55555e; font-size: 12px; }
</style></head>
<body><main>
  <h1>headless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="keys">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; drag</kbd></div>    <div>move the window</div>
    <div class="k"><kbd>&#8963;&#8984; F</kbd></div><div>fullscreen</div>
    <div class="k"><kbd>&#8679;&#8984; S</kbd></div><div>snapshot the page &rarr; desktop</div>
    <div class="k"><kbd>&#8984; P</kbd></div>       <div>pin on top of every window</div>
    <div class="k"><kbd>&#8984; [</kbd> <kbd>&#8984; ]</kbd></div><div>back / forward</div>
    <div class="k"><kbd>esc</kbd></div>             <div>bail out &mdash; back to this page</div>
    <div class="k"><kbd>&#8984; =</kbd> <kbd>&#8984; &minus;</kbd> <kbd>&#8984; 0</kbd></div><div>zoom</div>
    <div class="k"><kbd>&#8679;&#8984; C</kbd></div><div>copy current url</div>
  </div>
  <footer>&#8984;N new window &nbsp;&middot;&nbsp; &#8984;R reload &nbsp;&middot;&nbsp; &#8984;W close</footer>
</main></body></html>
"""

// MARK: - Views

final class BrowserWebView: WKWebView {
    // Bare Esc escapes back to the start page — unless fullscreen needs it,
    // or the ⌘L HUD is open (its field is first responder and handles Esc itself).
    var onEscape: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           window?.styleMask.contains(.fullScreen) != true,
           fullscreenState == .notInFullscreen,
           onEscape?() == true {
            return
        }
        super.keyDown(with: event)
    }

    // ⌘-drag anywhere moves the window; mouse buttons 4/5 go back/forward.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, canGoBack { goBack(); return }
        if event.buttonNumber == 4, canGoForward { goForward(); return }
        super.otherMouseUp(with: event)
    }
}

final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    let webView: BrowserWebView
    let qaBridge: WebKitQABridge
    private let progressBar = NSView()
    private let hud = NSVisualEffectView()
    private let hudField = NSTextField()
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var mouseMonitor: Any?
    private var snapJob: SnapJob?
    private var toastHide: DispatchWorkItem?
    private var lastProgress: CGFloat = 0
    private var onStartPage = false
    private var pendingRestoredStartupURL: URL?
    private var agentControlEnabled = false
    var onClose: (() -> Void)?

    init(
        url: URL?, restoredStartupURL: URL? = nil, size: NSSize?, snap: SnapJob?, isPrimary: Bool
    ) {
        let diagnosticsBridge = WebKitQABridge()
        qaBridge = diagnosticsBridge
        let conf = WKWebViewConfiguration()
        conf.preferences.isElementFullscreenEnabled = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.allowsAirPlayForMediaPlayback = true
        conf.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        conf.userContentController.add(diagnosticsBridge, name: "headlessQA")
        conf.userContentController.addUserScript(WKUserScript(
            source: webKitQAScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        conf.userContentController.addUserScript(WKUserScript(
            source: agentRuntimeJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: agentWorld
        ))
        if !hasPasskeyEntitlement {
            let hideWebAuthn = WKUserScript(
                source: """
                (function () {
                  try {
                    delete window.PublicKeyCredential;
                    delete window.AuthenticatorResponse;
                    delete window.AuthenticatorAttestationResponse;
                    delete window.AuthenticatorAssertionResponse;
                  } catch (e) {}
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false)
            conf.userContentController.addUserScript(hideWebAuthn)
        }
        webView = BrowserWebView(frame: .zero, configuration: conf)
        snapJob = snap

        let contentSize = size ?? NSSize(width: 1160, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Headless"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 220)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        setTrafficLights(visible: false)

        let container = LayoutReportingView(frame: NSRect(origin: .zero, size: contentSize))
        container.onLayout = { [weak self] in self?.layoutOverlays() }
        window.contentView = container

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.onEscape = { [weak self] in self?.escapeToStart() ?? false }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        container.addSubview(webView)

        buildOverlays(in: container)
        observeWebView()

        window.center()
        if isPrimary && snap == nil {
            window.setFrameUsingName("HeadlessMain")
            window.setFrameAutosaveName("HeadlessMain")
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 30, y: key.frame.maxY - 30))
        }
        if let size { window.setContentSize(size) }

        installMouseMonitor()

        if let url {
            pendingRestoredStartupURL = restoredStartupURL
            load(url)
        } else {
            loadStartPage()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Chrome (what little there is)

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .mouseMoved {
                // Reveal the traffic lights only when hovering the top-left corner.
                guard let contentView = self.window?.contentView else { return event }
                let p = event.locationInWindow
                let nearCorner = p.y > contentView.bounds.height - 44 && p.x < 96
                self.setTrafficLights(visible: self.isFullScreen || nearCorner)
            } else if !self.hud.isHidden {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if !self.hud.frame.contains(p) { self.hideHUD() }
            }
            return event
        }
    }

    private func buildOverlays(in container: NSView) {
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.alphaValue = 0
        container.addSubview(progressBar)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 26
        hud.layer?.cornerCurve = .continuous
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hud.isHidden = true
        hud.alphaValue = 0
        hudField.isBezeled = false
        hudField.isBordered = false
        hudField.drawsBackground = false
        hudField.focusRingType = .none
        hudField.font = .systemFont(ofSize: 16)
        hudField.textColor = .labelColor
        hudField.placeholderString = "Search or enter address"
        hudField.usesSingleLineMode = true
        hudField.cell?.isScrollable = true
        hudField.cell?.wraps = false
        hudField.delegate = self
        hud.addSubview(hudField)
        container.addSubview(hud)

        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 17
        toastView.layer?.cornerCurve = .continuous
        toastView.layer?.masksToBounds = true
        toastView.isHidden = true
        toastView.alphaValue = 0
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastView.addSubview(toastLabel)
        container.addSubview(toastView)
    }

    private func layoutOverlays() {
        guard let contentView = window?.contentView else { return }
        let b = contentView.bounds
        let hudW = min(620, max(280, b.width - 48))
        let hudH: CGFloat = 52
        hud.frame = NSRect(x: (b.width - hudW) / 2, y: b.height - hudH - 84, width: hudW, height: hudH)
        hudField.frame = NSRect(x: 20, y: (hudH - 22) / 2, width: hudW - 40, height: 22)

        toastLabel.sizeToFit()
        let ts = toastLabel.frame.size
        let tw = ts.width + 32
        let th: CGFloat = 34
        toastView.frame = NSRect(x: (b.width - tw) / 2, y: 28, width: tw, height: th)
        toastLabel.frame = NSRect(x: 16, y: (th - ts.height) / 2, width: ts.width, height: ts.height)

        progressBar.frame = NSRect(x: 0, y: b.height - 2, width: b.width * lastProgress, height: 2)
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progressChanged(wv.estimatedProgress)
            },
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.window?.title = t.isEmpty ? "Headless" : t
            },
            webView.observe(\.url) { wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
                }
            },
        ]
    }

    private func progressChanged(_ progress: Double) {
        lastProgress = CGFloat(progress)
        if let width = window?.contentView?.bounds.width {
            progressBar.frame.size.width = width * lastProgress
        }
        if progress >= 1.0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.lastProgress = 0
                self?.layoutOverlays()
            })
        } else {
            progressBar.alphaValue = 1
        }
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        pendingRestoredStartupURL = nil
        load(url)
    }

    private func load(_ url: URL) {
        onStartPage = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Once a window is driven through the local agent protocol, abandon any
    /// legacy local page before its contents can become agent-visible.
    func enableAgentControl() {
        if !agentControlEnabled,
           let currentURL = webView.url,
           currentURL.absoluteString != "about:blank",
           !agentMayNavigate(to: currentURL) {
            // Older builds allowed a user to open file or application URLs.
            // Do not make restored legacy content readable to an agent.
            loadStartPage()
        }
        agentControlEnabled = true
    }

    func loadStartPage() {
        pendingRestoredStartupURL = nil
        onStartPage = true
        webView.loadHTMLString(startPageHTML, baseURL: nil)
    }

    private func escapeToStart() -> Bool {
        if onStartPage { return false }
        loadStartPage()
        return true
    }

    // MARK: HUD (the ⌘L address bar)

    func showHUD() {
        if let u = webView.url, !onStartPage, u.absoluteString != "about:blank" {
            hudField.stringValue = u.absoluteString
        } else {
            hudField.stringValue = ""
        }
        hud.isHidden = false
        layoutOverlays()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
        }
        hudField.selectText(nil)
    }

    func hideHUD() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hud.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    private func commitHUD() {
        let text = hudField.stringValue
        hideHUD()
        if let url = smartURL(text) { navigate(to: url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideHUD(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitHUD(); return true }
        return false
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        layoutOverlays()
        toastHide?.cancel()
        toastView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.toastView.animator().alphaValue = 0
            }, completionHandler: { self.toastView.isHidden = true })
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    // MARK: Snapshots

    private func writePNG(from image: NSImage, to path: String) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return (cg.width, cg.height)
        } catch {
            return nil
        }
    }

    private func runSnapJob(_ job: SnapJob) {
        DispatchQueue.main.asyncAfter(deadline: .now() + job.wait) { [weak self] in
            guard let self else { exit(3) }
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let dims = self.writePNG(from: image, to: job.path) else {
                    fputs("headless: snapshot failed: \(error?.localizedDescription ?? "could not write PNG")\n", stderr)
                    exit(3)
                }
                print("saved \(job.path) (\(dims.0)x\(dims.1) px)")
                exit(0)
            }
        }
    }

    // MARK: Menu actions

    @objc func openLocation(_ sender: Any?) { showHUD() }

    @objc func reloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reload() }
    }

    @objc func hardReloadPage(_ sender: Any?) {
        if onStartPage { loadStartPage() } else { webView.reloadFromOrigin() }
    }

    @objc func goBackAction(_ sender: Any?) { webView.goBack() }
    @objc func goForwardAction(_ sender: Any?) { webView.goForward() }

    @objc func zoomInPage(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom * 1.1, 5.0) }
    @objc func zoomOutPage(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom / 1.1, 0.25) }
    @objc func resetZoom(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc func saveSnapshot(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "headless \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = desktop.appendingPathComponent(name).path
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            if let image, self.writePNG(from: image, to: path) != nil {
                self.showToast("Saved “\(name)” to Desktop")
            } else {
                self.showToast("Snapshot failed")
            }
        }
    }

    @objc func copyPageURL(_ sender: Any?) {
        guard let u = webView.url, u.absoluteString != "about:blank" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let window else { return }
        let pinned = window.level == .floating
        window.level = pinned ? .normal : .floating
        showToast(pinned ? "Unpinned" : "Pinned on top")
    }

    @objc func showHelpPage(_ sender: Any?) { loadStartPage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)): return webView.canGoBack
        case #selector(goForwardAction(_:)): return webView.canGoForward
        case #selector(copyPageURL(_:)):
            return webView.url != nil && webView.url?.absoluteString != "about:blank"
        case #selector(togglePin(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { setTrafficLights(visible: true) }
    func windowDidExitFullScreen(_ notification: Notification) { setTrafficLights(visible: false) }

    func windowWillClose(_ notification: Notification) {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        observations.removeAll()
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        qaBridge.beginDocument()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let u = webView.url?.absoluteString
        if u != nil && u != "about:blank" {
            pendingRestoredStartupURL = nil
            onStartPage = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let job = snapJob {
            snapJob = nil
            runSnapJob(job)
        } else if onStartPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.onStartPage, self.window?.isKeyWindow == true else { return }
                self.showHUD()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        // Ignore cancelled loads and "frame load interrupted" (downloads, redirects).
        if e.code == NSURLErrorCancelled || e.code == 102 { return }
        qaBridge.store.append(kind: "request-failed", message: e.localizedDescription,
                              url: webView.url?.absoluteString)
        if let restoredURL = pendingRestoredStartupURL {
            pendingRestoredStartupURL = nil
            if UserDefaults.standard.string(forKey: "LastURL") == restoredURL.absoluteString {
                UserDefaults.standard.removeObject(forKey: "LastURL")
            }
            loadStartPage()
            showToast("Previous page unavailable")
            return
        }
        if launchOptions.snap != nil {
            fputs("headless: load failed: \(e.localizedDescription)\n", stderr)
            exit(1)
        }
        showToast("Couldn’t load — \(e.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           !(onStartPage && url.absoluteString == "about:blank"),
           !agentMayNavigate(to: url) {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            // Convert explicit download intent into WKDownload so the
            // delegate below can classify and cancel it deterministically.
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            qaBridge.store.append(kind: "response", url: response.url?.absoluteString,
                                  method: "GET", status: Double(response.statusCode))
            if response.value(forHTTPHeaderField: "Content-Disposition")?
                .lowercased().contains("attachment") == true {
                decisionHandler(.download)
                return
            }
        }
        if !navigationResponse.canShowMIMEType {
            // Unsupported navigation responses would otherwise become
            // implicit downloads. Route them through the same fail-closed
            // cancellation and diagnostic path.
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    // WebKit creates a WKDownload for attachment responses and `download`
    // links. Agent sessions must never turn page-controlled bytes into files
    // on the host; only ArtifactStore owns explicit screenshot/recording
    // outputs. Cancelling here also covers otherwise safe-looking archives.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        blockDownload(download, url: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        blockDownload(download, url: navigationResponse.response.url)
    }

    private func blockDownload(_ download: WKDownload, url: URL?) {
        qaBridge.store.append(kind: "download-blocked", message: "Blocked page-initiated download", url: url?.absoluteString)
        download.cancel { _ in }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No tabs, no popups: target=_blank loads right here.
        if let url = navigationAction.request.url,
           agentMayNavigate(to: url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

// MARK: - App delegate

private func onAgentMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [BrowserWindowController] = []
    private let agentServer = LocalSocketServer()
    private var agentSessions: [String: BrowserWindowController] = [:]
    private var agentTrace: [String: [JSONValue]] = [:]
    private var activeFlows: [String: [RecordedFlowStep]] = [:]
    private var recordings: [String: BrowserRecording] = [:]
    private let recordingsLock = NSLock()
    private var artifacts: ArtifactStore?
    private let traceStartedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { artifacts = try ArtifactStore() }
        catch {
            fputs("headless: artifact directory failed: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let restoredStartupURL: URL? = {
            guard !isAgentHost, launchOptions.url == nil, launchOptions.snap == nil,
                  let value = UserDefaults.standard.string(forKey: "LastURL") else { return nil }
            return URL(string: value)
        }()
        let url = isAgentHost ? nil : launchOptions.url ?? restoredStartupURL
        openWindow(
            url: url,
            restoredStartupURL: restoredStartupURL,
            size: launchOptions.size,
            snap: launchOptions.snap,
            isPrimary: true,
            sessionName: "default"
        )
        do {
            try agentServer.start { [weak self] request in
                self?.handleAgentRequest(request) ?? CommandResponse.failure(
                    id: request.id, code: "HOST_STOPPING", message: "Headless host is stopping."
                )
            }
        } catch {
            fputs("headless: agent socket failed: \(error)\n", stderr)
        }
        NSApp.activate(ignoringOtherApps: true)

        if launchOptions.snap != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("headless: --snap timed out\n", stderr)
                exit(2)
            }
        }
    }

    @discardableResult
    func openWindow(
        url: URL?,
        restoredStartupURL: URL? = nil,
        size: NSSize? = nil,
        snap: SnapJob? = nil,
        isPrimary: Bool = false,
        sessionName: String? = nil
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(
            url: url,
            restoredStartupURL: restoredStartupURL,
            size: size,
            snap: snap,
            isPrimary: isPrimary
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
            let closedSessions = self.agentSessions.compactMap { $0.value === controller ? $0.key : nil }
            for session in closedSessions {
                self.agentSessions.removeValue(forKey: session)
                self.agentTrace.removeValue(forKey: session)
                self.activeFlows.removeValue(forKey: session)
            }
            let stoppedRecordings = closedSessions.compactMap { self.takeRecording(for: $0) }
            DispatchQueue.global(qos: .utility).async {
                for recording in stoppedRecordings { _ = try? recording.stop(timeout: 5) }
            }
        }
        controllers.append(controller)
        if let sessionName {
            agentSessions[sessionName] = controller
            agentTrace[sessionName] = []
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }

    // Agent hosts must stay alive when the last session window closes; the CLI
    // owns process lifetime via `headless stop` / shutdown.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !isAgentHost }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for recording in takeAllRecordings() { _ = try? recording.stop(timeout: 5) }
        agentServer.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(url: url) }
    }

    private func captureScreenshotSeries(
        controller: BrowserWindowController,
        parameters: [String: JSONValue]
    ) throws -> JSONValue {
        guard let artifacts else { throw ArtifactError.invalidRoot }
        let mode = parameters["series"]?.stringValue ?? "viewport"
        let format = try screenshotFormat(
            explicit: parameters["format"]?.stringValue,
            output: nil
        )
        let rawPlan = try controller.agentScreenshotSeriesPlan(mode: mode)
        let plan = try parseScreenshotSeriesPlan(rawPlan)
        let points = plan.points
        let prefix = try screenshotSeriesPrefix(parameters: parameters, mode: mode)
        defer { _ = try? controller.agentScrollToCapturePoint(y: plan.initialY) }
        let reserved = try reserveScreenshotSeriesArtifacts(
            store: artifacts, points: points, prefix: prefix, mode: mode, format: format
        )
        do {
            let metadata = try points.enumerated().map { index, point -> JSONValue in
                _ = try controller.agentScrollToCapturePoint(y: point.y)
                let data = try controller.agentScreenshotData(
                    parameters: [:], format: format, copyToClipboard: false
                ).data
                return try artifacts.writeReserved(data, to: reserved[index])
            }
            return screenshotSeriesSummary(
                mode: mode, points: points, artifacts: metadata,
                truncated: plan.truncated, totalPoints: plan.totalPoints
            )
        } catch {
            artifacts.discardReserved(reserved)
            throw error
        }
    }

    // MARK: Agent protocol

    private func handleAgentRequest(_ request: CommandRequest) -> CommandResponse {
        if request.command == .ping {
            return .success(id: request.id, result: .object([
                "ready": .bool(true),
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "engine": .string("webkit"),
                "platform": .string("macos"),
                "protocolVersion": .string(headlessProtocolVersion),
                "recordingAvailable": .bool(BrowserRecording.isAvailable()),
                "artifactDirectory": .string(artifacts?.rootURL.path ?? ""),
            ]))
        }
        if request.command == .shutdown {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return .success(id: request.id, result: .object(["stopping": .bool(true)]))
        }

        switch request.command {
        case .artifactList:
            do {
                guard let artifacts else { throw ArtifactError.invalidRoot }
                return .success(id: request.id, result: try artifacts.list())
            } catch {
                return failure(request, code: "ARTIFACT_ERROR", message: String(describing: error))
            }
        case .sessionCreate:
            guard let name = request.parameters["name"]?.stringValue else {
                return failure(request, code: "MISSING_PARAMETER", message: "Session name is required.")
            }
            do {
                try validateIdentifier(name, field: "session")
            } catch {
                return failure(request, code: "INVALID_SESSION", message: String(describing: error))
            }
            return onAgentMain {
                if self.agentSessions[name] != nil {
                    return self.failure(request, code: "SESSION_EXISTS", message: "Session already exists: \(name)")
                }
                let controller = self.openWindow(url: nil, sessionName: name)
                controller.enableAgentControl()
                self.recordTrace(command: request.command, session: name)
                return .success(id: request.id, result: .object(["session": .string(name)]))
            }
        case .sessionList:
            return onAgentMain {
                let sessions = self.agentSessions.keys.sorted().map { JSONValue.string($0) }
                return .success(id: request.id, result: .object(["sessions": .array(sessions)]))
            }
        case .sessionClose:
            let name = request.session ?? "default"
            guard let controller = onAgentMain({ self.agentSessions[name] }) else {
                return missingSession(request, name)
            }
            let recording = takeRecording(for: name)
            onAgentMain {
                self.agentSessions.removeValue(forKey: name)
                self.agentTrace.removeValue(forKey: name)
                self.activeFlows.removeValue(forKey: name)
                controller.close()
            }
            if let recording { _ = try? recording.stop(timeout: 5) }
            return .success(id: request.id, result: .object(["closed": .string(name)]))
        default:
            break
        }

        let session = request.session ?? "default"
        guard let controller = onAgentMain({ self.agentSessions[session] }) else {
            return missingSession(request, session)
        }
        onAgentMain { controller.enableAgentControl() }

        do {
            let result: JSONValue
            switch request.command {
            case .visit:
                guard let value = request.parameters["url"]?.stringValue else {
                    return failure(request, code: "MISSING_PARAMETER", message: "URL is required.")
                }
                result = try controller.agentVisit(normalizedWebURL(value))
            case .inspect:
                result = try controller.agentInspect(parameters: request.parameters)
            case .click:
                result = try controller.agentClick(parameters: request.parameters)
            case .fill:
                result = try controller.agentFill(parameters: request.parameters)
            case .press:
                result = try controller.agentPress(parameters: request.parameters)
            case .scroll:
                result = try controller.agentScroll(parameters: request.parameters)
            case .wait:
                result = try controller.agentWait(parameters: request.parameters)
            case .tour:
                result = try controller.agentTour(parameters: request.parameters)
            case .captureInfo:
                let info = try controller.agentCaptureInfo()
                let trace = onAgentMain { self.agentTrace[session] ?? [] }
                if case .object(var object) = info {
                    object["trace"] = .array(trace)
                    object["recording"] = recording(for: session)?.status() ?? .object(["active": .bool(false)])
                    result = .object(object)
                } else {
                    result = info
                }
            case .back:
                onAgentMain { _ = controller.webView.goBack() }
                result = try controller.agentWait(parameters: ["settled": .bool(true)])
            case .reload:
                _ = onAgentMain { controller.webView.reload() }
                result = try controller.agentWait(parameters: ["settled": .bool(true)])
            case .screenshot:
                guard let artifacts else { throw ArtifactError.invalidRoot }
                if request.parameters["series"]?.stringValue != nil {
                    result = try captureScreenshotSeries(controller: controller, parameters: request.parameters)
                } else {
                    let format = try screenshotFormat(
                        explicit: request.parameters["format"]?.stringValue,
                        output: request.parameters["output"]?.stringValue
                    )
                    let artifact = try controller.agentScreenshotData(
                        parameters: request.parameters,
                        format: format,
                        copyToClipboard: request.parameters["clipboard"]?.boolValue ?? false
                    )
                    var metadata = try artifacts.write(
                        artifact.data, requestedName: request.parameters["output"]?.stringValue,
                        extension: artifactExtension(request.parameters["output"]?.stringValue ?? "") ?? format.fileExtension,
                        prefix: "screenshot-\(session)"
                    )
                    if artifact.clipboardCopied {
                        metadata = merge(metadata, with: .object(["clipboard": .bool(true)]))
                    }
                    result = metadata
                }
            case .recordStart:
                guard recording(for: session) == nil else { throw RecordingError.alreadyActive }
                guard let artifacts else { throw ArtifactError.invalidRoot }
                let format = try recordingFormat(
                    explicit: request.parameters["format"]?.stringValue,
                    output: request.parameters["output"]?.stringValue
                )
                let quality = try RecordingQuality.parse(request.parameters["quality"]?.stringValue ?? "balanced")
                let output = try artifacts.reserve(
                    requestedName: request.parameters["output"]?.stringValue,
                    extension: format.fileExtension, prefix: "recording-\(session)"
                )
                let fps = request.parameters["fps"]?.numberValue ?? 10
                var startedRecording: BrowserRecording?
                do {
                    let recording = try BrowserRecording(
                        outputURL: output, fps: fps, format: format, quality: quality
                    ) { [weak controller] in
                        guard let controller else { throw RecordingError.captureFailed("session closed") }
                        return try controller.agentScreenshot(parameters: [:])
                    }
                    startedRecording = recording
                    try storeRecording(recording, for: session)
                } catch {
                    if let startedRecording { _ = try? startedRecording.stop(timeout: 5) }
                    try? FileManager.default.removeItem(at: output)
                    throw error
                }
                guard let recording = startedRecording else { throw RecordingError.captureFailed("recorder did not start") }
                result = recording.status()
            case .recordStatus:
                result = recording(for: session)?.status() ?? .object(["active": .bool(false)])
            case .recordStop:
                guard let activeRecording = recording(for: session) else {
                    throw RecordingError.notActive
                }
                guard let artifacts else { throw ArtifactError.invalidRoot }
                if let output = request.parameters["output"]?.stringValue,
                   let actual = artifactExtension(output),
                   actual != activeRecording.format.fileExtension {
                    throw CaptureFormatError.mismatchedOutputFormat(
                        expected: activeRecording.format.fileExtension,
                        actual: actual
                    )
                }
                guard let recording = takeRecording(for: session) else { throw RecordingError.notActive }
                let status: JSONValue
                do { status = try recording.stop() }
                catch {
                    try? FileManager.default.removeItem(at: recording.outputURL)
                    throw error
                }
                let artifact = try artifacts.finalize(
                    recording.outputURL, renameTo: request.parameters["output"]?.stringValue
                )
                result = merge(status, with: artifact)
            case .qaReport:
                result = controller.agentQAReport()
            case .qaClear:
                result = controller.agentQAClear()
            case .consoleList:
                result = controller.agentConsole(
                    level: request.parameters["level"]?.stringValue ?? "all",
                    limit: Int(request.parameters["limit"]?.numberValue ?? 100)
                )
            case .networkList:
                result = controller.agentNetwork(
                    failedOnly: request.parameters["failed"]?.boolValue ?? false,
                    status: request.parameters["status"]?.numberValue.map(Int.init),
                    limit: Int(request.parameters["limit"]?.numberValue ?? 100)
                )
            case .networkGet:
                guard let requestID = request.parameters["requestId"]?.stringValue else {
                    return failure(request, code: "MISSING_PARAMETER", message: "Network request ID is required.")
                }
                result = controller.agentNetworkDetail(requestID: requestID)
            case .stylesGet:
                result = try controller.agentStyles(parameters: request.parameters)
            case .cookiesList:
                result = try controller.agentCookies(
                    includeValues: request.parameters["includeValues"]?.boolValue ?? false
                )
            case .storageList:
                result = try controller.agentStorage(
                    scope: request.parameters["scope"]?.stringValue ?? "all",
                    includeValues: request.parameters["includeValues"]?.boolValue ?? false
                )
            case .performanceGet:
                result = try controller.agentPerformance()
            case .animationList:
                result = try controller.agentAnimations()
            case .visualCompare:
                guard let before = request.parameters["before"]?.stringValue else {
                    return failure(request, code: "MISSING_PARAMETER", message: "Before artifact name is required.")
                }
                guard let after = request.parameters["after"]?.stringValue else {
                    return failure(request, code: "MISSING_PARAMETER", message: "After artifact name is required.")
                }
                guard let artifacts else { throw ArtifactError.invalidRoot }
                _ = try artifacts.read(name: before, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
                _ = try artifacts.read(name: after, expectedExtension: "png", maximumBytes: 100 * 1_024 * 1_024)
                let difference = try artifacts.reserve(
                    requestedName: request.parameters["output"]?.stringValue,
                    extension: "png", prefix: "difference-\(session)"
                )
                let comparison = try VisualComparison.compare(
                    before: artifacts.rootURL.appendingPathComponent(before),
                    after: artifacts.rootURL.appendingPathComponent(after), difference: difference
                )
                result = merge(comparison, with: try artifacts.finalize(difference, renameTo: nil))
            case .reportCreate:
                guard let artifacts else { throw ArtifactError.invalidRoot }
                let report: JSONValue = .object([
                    "format": .string("headless-qa-report-v1"),
                    "createdAt": .number(Date().timeIntervalSince1970),
                    "session": .string(session),
                    "page": try controller.agentCaptureInfo(),
                    "qa": controller.agentQAReport(),
                    "trace": .array(onAgentMain { self.agentTrace[session] ?? [] }),
                    "artifacts": try artifacts.list(),
                    "security": .object(["sensitiveValuesIncluded": .bool(false), "transport": .string("local-unix-socket")]),
                ])
                let data = try ProtocolCodec.encoder.encode(report)
                result = try artifacts.write(data, requestedName: request.parameters["output"]?.stringValue,
                                             extension: "json", prefix: "qa-report-\(session)")
            case .flowStart:
                onAgentMain { self.activeFlows[session] = [] }
                result = .object(["recording": .bool(true), "note": .string("Only safe navigation actions are recorded; typed values and credentials are never stored.")])
            case .flowStop:
                guard let artifacts else { throw ArtifactError.invalidRoot }
                let steps = onAgentMain { self.activeFlows.removeValue(forKey: session) ?? [] }
                let data = try ProtocolCodec.encoder.encode(RecordedFlow(commands: steps))
                result = try artifacts.write(data, requestedName: request.parameters["output"]?.stringValue,
                                             extension: "json", prefix: "flow-\(session)")
            case .flowRun:
                guard let input = request.parameters["input"]?.stringValue else { return failure(request, code: "MISSING_PARAMETER", message: "Flow input is required.") }
                guard let artifacts else { throw ArtifactError.invalidRoot }
                let flow = try ProtocolCodec.decoder.decode(RecordedFlow.self, from: artifacts.read(name: input, expectedExtension: "json", maximumBytes: 1_024 * 1_024))
                guard flow.version == 1, flow.commands.count <= 200,
                      flow.commands.allSatisfy({ replayableFlowCommands.contains($0.command) }) else {
                    return failure(request, code: "INVALID_FLOW", message: "Flow contains unsupported commands.")
                }
                var completed = 0
                for step in flow.commands {
                    try CommandRequest(command: step.command, session: session, parameters: step.parameters).validate()
                    let response = handleAgentRequest(CommandRequest(command: step.command, session: session, parameters: step.parameters))
                    guard response.ok else {
                        return failure(request, code: "FLOW_FAILED", message: "Step \(completed + 1) (\(step.command.rawValue)) failed: \(response.error?.message ?? "unknown error")")
                    }
                    completed += 1
                }
                result = .object(["completed": .number(Double(completed)), "input": .string(input)])
            case .networkEmulate, .networkMockSet, .networkMockClear:
                return failure(request, code: "UNSUPPORTED_CAPABILITY", message: "Network simulation and request mocking require the Chromium CDP host on Linux.", suggestion: "Use the Linux runtime for controlled CDP network emulation; no partial WebKit interception is exposed.")
            case .ping, .shutdown, .sessionCreate, .sessionList, .sessionClose, .artifactList:
                return failure(request, code: "INVALID_COMMAND", message: "Command is not valid in this context.")
            }
            onAgentMain {
                self.recordTrace(command: request.command, session: session, result: result)
                if let step = flowStepIfSafe(command: request.command, parameters: request.parameters), self.activeFlows[session] != nil {
                    if (self.activeFlows[session]?.count ?? 0) < 200 { self.activeFlows[session]?.append(step) }
                }
            }
            return .success(id: request.id, result: result)
        } catch let error as HostError {
            return failure(
                request, code: error.code.rawValue, message: error.message,
                suggestion: error.suggestion
            )
        } catch let error as ProtocolValidationError {
            if case .unsafeResourceType = error {
                return failure(request, code: "UNSAFE_RESOURCE_TYPE", message: error.description,
                               suggestion: "Executable files, installers, scripts, and disk images are blocked. Use normal web pages or media only.")
            }
            return failure(request, code: "INVALID_URL", message: error.description)
        } catch let error as CaptureFormatError {
            return failure(request, code: "INVALID_CAPTURE_FORMAT", message: error.description)
        } catch let error as RecordingError {
            let code: String
            let suggestion: String?
            switch error {
            case .unavailable:
                code = "RECORDER_UNAVAILABLE"
                suggestion = "Install FFmpeg or set HEADLESS_FFMPEG_EXECUTABLE."
            case .alreadyActive: code = "RECORDING_ACTIVE"; suggestion = nil
            case .notActive: code = "RECORDING_NOT_ACTIVE"; suggestion = nil
            default: code = "RECORDING_FAILED"; suggestion = nil
            }
            return failure(request, code: code, message: error.description, suggestion: suggestion)
        } catch let error as ArtifactError {
            return failure(request, code: "ARTIFACT_ERROR", message: error.description)
        } catch {
            return failure(request, code: "INTERNAL_ERROR", message: String(describing: error))
        }
    }

    private func recordTrace(command: CommandName, session: String, result: JSONValue? = nil) {
        var event: [String: JSONValue] = [
            "time": .number(ProcessInfo.processInfo.systemUptime - traceStartedAt),
            "command": .string(command.rawValue),
        ]
        if case .object(let object) = result, let url = object["url"]?.stringValue {
            event["url"] = .string(String(decoding: url.utf8.prefix(2_048), as: UTF8.self))
        }
        var entries = agentTrace[session] ?? []
        entries.append(.object(event))
        if entries.count > 256 { entries.removeFirst(entries.count - 256) }
        agentTrace[session] = entries
    }

    private func recording(for session: String) -> BrowserRecording? {
        recordingsLock.lock(); defer { recordingsLock.unlock() }
        return recordings[session]
    }

    private func storeRecording(_ recording: BrowserRecording, for session: String) throws {
        recordingsLock.lock(); defer { recordingsLock.unlock() }
        guard recordings[session] == nil else { throw RecordingError.alreadyActive }
        recordings[session] = recording
    }

    private func takeRecording(for session: String) -> BrowserRecording? {
        recordingsLock.lock(); defer { recordingsLock.unlock() }
        return recordings.removeValue(forKey: session)
    }

    private func takeAllRecordings() -> [BrowserRecording] {
        recordingsLock.lock(); defer { recordingsLock.unlock() }
        let active = Array(recordings.values)
        recordings.removeAll()
        return active
    }

    private func missingSession(_ request: CommandRequest, _ name: String) -> CommandResponse {
        failure(request, code: "SESSION_NOT_FOUND", message: "Session does not exist: \(name)",
                suggestion: "Run `headless session create \(name)`." )
    }

    private func failure(
        _ request: CommandRequest,
        code: String,
        message: String,
        suggestion: String? = nil
    ) -> CommandResponse {
        .failure(id: request.id, code: code, message: message, suggestion: suggestion)
    }

    private func merge(_ first: JSONValue, with second: JSONValue) -> JSONValue {
        guard case .object(var result) = first, case .object(let extra) = second else { return second }
        result.merge(extra) { _, new in new }
        return .object(result)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Headless",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Headless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Headless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Headless", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newWin = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWin.target = self
        fileMenu.addItem(withTitle: "Open Location…",
                         action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
        fileMenu.addItem(.separator())
        let snap = fileMenu.addItem(withTitle: "Save Snapshot to Desktop",
                                    action: #selector(BrowserWindowController.saveSnapshot(_:)), keyEquivalent: "s")
        snap.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyURL = editMenu.addItem(withTitle: "Copy Current URL",
                                       action: #selector(BrowserWindowController.copyPageURL(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page",
                         action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "Reload Ignoring Cache",
                                          action: #selector(BrowserWindowController.hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BrowserWindowController.zoomOutPage(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back",
                            action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward",
                            action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
        main.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Pin on Top",
                           action: #selector(BrowserWindowController.togglePin(_:)), keyEquivalent: "p")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Headless Help",
                         action: #selector(BrowserWindowController.showHelpPage(_:)), keyEquivalent: "?")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Boot

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
