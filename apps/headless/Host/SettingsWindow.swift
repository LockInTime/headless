import AppKit
import HeadlessProtocol

private final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private static var sharedController: SettingsWindowController?

    static func orderFrontShared(_ sender: Any?) {
        if sharedController == nil {
            do {
                let store = try SettingsStore.production()
                sharedController = try SettingsWindowController(store: store)
            } catch {
                presentOpenFailure(error)
                return
            }
        }
        sharedController?.showWindow(sender)
        sharedController?.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Couldn’t open Settings"
        alert.informativeText = (error as? SettingsError)?.description ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private let settings: SettingsController
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedSettingsDocumentView()
    private var isReloading = false
    private var firstEditor: NSView?

    private init(store: SettingsStore) throws {
        settings = SettingsController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 400, height: 240)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("HeadlessSettings")
        window.identifier = NSUserInterfaceItemIdentifier("headless-settings")
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        buildContent()
        try reload()
        let fitted = max(stack.fittingSize.height + 8, 260)
        window.setContentSize(NSSize(width: 520, height: min(fitted, 640)))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowDidBecomeKey(_ notification: Notification) {
        try? reload()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    private func reload() throws {
        isReloading = true
        defer { isReloading = false }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        firstEditor = nil
        let snapshots = try settings.snapshots()
        if snapshots.isEmpty {
            stack.addArrangedSubview(wrappingLabel("No settings are registered.", bold: false))
            return
        }
        for snapshot in snapshots {
            let section = makeSection(snapshot)
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -44).isActive = true
        }
        window?.initialFirstResponder = firstEditor
        window?.recalculateKeyViewLoop()
        if window?.isKeyWindow == true, let firstEditor {
            window?.makeFirstResponder(firstEditor)
        }
    }

    private func makeSection(_ snapshot: SettingSnapshot) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setHuggingPriority(.defaultLow, for: .horizontal)

        let title = wrappingLabel(snapshot.definition.key, bold: true)
        title.setAccessibilityLabel(snapshot.definition.key)
        section.addArrangedSubview(title)

        let summary = wrappingLabel(snapshot.definition.summary, bold: false)
        summary.textColor = .secondaryLabelColor
        summary.setAccessibilityLabel("Summary")
        section.addArrangedSubview(summary)

        let editor = makeEditor(snapshot)
        if firstEditor == nil { firstEditor = editor }
        let reset = NSButton(
            title: "Reset to Default",
            target: self,
            action: #selector(resetClicked(_:))
        )
        reset.bezelStyle = .rounded
        reset.identifier = NSUserInterfaceItemIdentifier("reset.\(snapshot.definition.key)")
        reset.setAccessibilityLabel("Reset \(snapshot.definition.key) to default")
        reset.isEnabled = snapshot.configured && snapshot.supportedOnCurrentPlatform

        let valueCaption = NSTextField(labelWithString: "Value")
        valueCaption.setAccessibilityHidden(true)
        let valueRow = NSStackView(views: [valueCaption, editor, reset])
        valueRow.orientation = .horizontal
        valueRow.alignment = .centerY
        valueRow.spacing = 8
        section.addArrangedSubview(valueRow)

        section.addArrangedSubview(metaLabel("Default", snapshot.displayedDefaultValue))
        section.addArrangedSubview(metaLabel("Platform", snapshot.platformSummary))
        section.addArrangedSubview(metaLabel("Takes effect", snapshot.definition.restartBehavior.rawValue))
        section.addArrangedSubview(
            metaLabel("Agents may modify", snapshot.agentsMayModify ? "yes" : "no")
        )
        return section
    }

    private func makeEditor(_ snapshot: SettingSnapshot) -> NSView {
        let key = snapshot.definition.key
        if let values = snapshot.selectableValues {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.autoenablesItems = false
            popup.addItems(withTitles: values)
            popup.selectItem(withTitle: snapshot.value)
            popup.target = self
            popup.action = #selector(valueChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(key)
            popup.setAccessibilityLabel(key)
            popup.setAccessibilityHelp(snapshot.definition.summary)
            popup.isEnabled = snapshot.supportedOnCurrentPlatform
            return popup
        }

        let field: NSTextField
        if snapshot.usesSecureTextEntry {
            let secureField = NSSecureTextField(string: snapshot.value)
            secureField.setAccessibilityValue("Hidden")
            secureField.placeholderString = "Hidden"
            field = secureField
        } else {
            field = NSTextField(string: snapshot.value)
            field.placeholderString = snapshot.definition.defaultValue
        }
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.delegate = self
        field.target = self
        field.action = #selector(textCommitted(_:))
        field.setAccessibilityLabel(key)
        field.setAccessibilityHelp(snapshot.definition.summary)
        field.isEditable = snapshot.supportedOnCurrentPlatform
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return field
    }

    private func wrappingLabel(_ text: String, bold: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 476
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func metaLabel(_ name: String, _ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: "\(name): \(value)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityLabel(name)
        label.setAccessibilityValue(value)
        return label
    }

    @objc private func valueChanged(_ sender: NSPopUpButton) {
        guard !isReloading, let key = sender.identifier?.rawValue else { return }
        commit(key, sender.titleOfSelectedItem ?? "")
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        guard !isReloading, let key = sender.identifier?.rawValue else { return }
        commit(key, sender.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textCommitted(field)
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("reset.") else { return }
        let key = String(raw.dropFirst("reset.".count))
        do {
            _ = try settings.reset(key)
            reloadAfterCurrentEvent()
        } catch {
            present(error)
            reloadAfterCurrentEvent()
        }
    }

    private func commit(_ key: String, _ rawValue: String) {
        do {
            let current = try settings.store.snapshot(key, caller: .user)
            guard current.value != rawValue || !current.configured else { return }
            _ = try settings.set(key, rawValue: rawValue)
            reloadAfterCurrentEvent()
        } catch {
            present(error)
            reloadAfterCurrentEvent()
        }
    }

    private func reloadAfterCurrentEvent() {
        DispatchQueue.main.async { [weak self] in
            do {
                try self?.reload()
            } catch {
                self?.present(error)
            }
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t update settings"
        alert.informativeText = (error as? SettingsError)?.description ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
