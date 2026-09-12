import Foundation

/// Portable catalog of macOS app menu shortcuts. The Cocoa host builds real
/// `NSMenuItem`s from these specs so chords, selectors, and targets stay one
/// source. The protocol suite rejects duplicate physical chords.
public enum MenuShortcutTarget: String, Equatable, Sendable {
    case application
    case appDelegate
    case firstResponder
}

public struct MenuShortcutSpec: Equatable, Sendable {
    public let menu: String
    public let title: String
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let selector: String
    public let target: MenuShortcutTarget
    public let separatorBefore: Bool

    public init(
        menu: String,
        title: String,
        key: String,
        command: Bool = true,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        selector: String,
        target: MenuShortcutTarget = .firstResponder,
        separatorBefore: Bool = false
    ) {
        self.menu = menu
        self.title = title
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.selector = selector
        self.target = target
        self.separatorBefore = separatorBefore
    }

    public var chordIdentity: String {
        [
            command ? "cmd" : nil,
            control ? "ctrl" : nil,
            option ? "opt" : nil,
            shift ? "shift" : nil,
            key.isEmpty ? nil : key.lowercased(),
        ].compactMap { $0 }.joined(separator: "+")
    }
}

public let headlessMenuShortcuts: [MenuShortcutSpec] = [
    .init(
        menu: "Headless", title: "Hide Headless", key: "h", selector: "hide:",
        target: .application
    ),
    .init(
        menu: "Headless", title: "Hide Others", key: "h", option: true,
        selector: "hideOtherApplications:", target: .application
    ),
    .init(
        menu: "Headless", title: "Quit Headless", key: "q", selector: "terminate:",
        target: .application
    ),
    .init(
        menu: "File", title: "New Window", key: "n", selector: "newWindow:",
        target: .appDelegate
    ),
    .init(menu: "File", title: "Open Location…", key: "l", selector: "openLocation:"),
    .init(
        menu: "File", title: "Save Snapshot to Desktop", key: "s", shift: true,
        selector: "saveSnapshot:", separatorBefore: true
    ),
    .init(
        menu: "File", title: "Close Window", key: "w", selector: "performClose:",
        separatorBefore: true
    ),
    .init(menu: "Edit", title: "Undo", key: "z", selector: "undo:"),
    .init(menu: "Edit", title: "Redo", key: "z", shift: true, selector: "redo:"),
    .init(menu: "Edit", title: "Cut", key: "x", selector: "cut:", separatorBefore: true),
    .init(menu: "Edit", title: "Copy", key: "c", selector: "copy:"),
    .init(menu: "Edit", title: "Paste", key: "v", selector: "paste:"),
    .init(menu: "Edit", title: "Select All", key: "a", selector: "selectAll:"),
    .init(
        menu: "Edit", title: "Copy Current URL", key: "c", shift: true,
        selector: "copyPageURL:", separatorBefore: true
    ),
    .init(menu: "View", title: "Reload Page", key: "r", selector: "reloadPage:"),
    .init(
        menu: "View", title: "Reload Ignoring Cache", key: "r", shift: true,
        selector: "hardReloadPage:"
    ),
    .init(
        menu: "View", title: "Zoom In", key: "=", selector: "zoomInPage:",
        separatorBefore: true
    ),
    .init(menu: "View", title: "Zoom Out", key: "-", selector: "zoomOutPage:"),
    .init(menu: "View", title: "Actual Size", key: "0", selector: "resetZoom:"),
    .init(
        menu: "View", title: "Enter Full Screen", key: "f", control: true,
        selector: "toggleFullScreen:", separatorBefore: true
    ),
    .init(menu: "History", title: "Back", key: "[", selector: "goBackAction:"),
    .init(menu: "History", title: "Forward", key: "]", selector: "goForwardAction:"),
    .init(menu: "Window", title: "Minimize", key: "m", selector: "performMiniaturize:"),
    .init(
        menu: "Window", title: "Pin on Top", key: "p", option: true,
        selector: "togglePin:", separatorBefore: true
    ),
    .init(
        menu: "Help", title: "Headless Help", key: "/", shift: true,
        selector: "showHelpPage:"
    ),
]
