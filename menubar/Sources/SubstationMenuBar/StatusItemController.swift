import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem: left-click toggles the SwiftUI popover,
/// right-click / control-click pops the admin menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    /// The transformer mark (assets/substation.svg shipped as a resource);
    /// template mode tints it to match the menu bar appearance.
    static func logoImage(template: Bool = true) -> NSImage? {
        if let url = Bundle.module.url(forResource: "substation", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            let h: CGFloat = 18
            img.size = NSSize(width: h * 249.0 / 281.0, height: h)
            img.isTemplate = template
            return img
        }
        let fallback = NSImage(systemSymbolName: "cube.box.fill", accessibilityDescription: "Substation")
        if template { fallback?.isTemplate = true }
        return fallback
    }

    private var statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.logoImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView(model: model))
        if #available(macOS 13.0, *) {
            host.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = host

        buildMenu()
        refresh()

        model.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Status item appearance

    func refresh() {
        guard let button = statusItem.button else { return }
        let title = model.barTitle
        let showBadge = model.isOnline && model.isPaused

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: model.isOnline ? NSColor.labelColor : NSColor.disabledControlTextColor,
        ]
        var text = NSAttributedString(string: title, attributes: attributes)
        if model.degradedAuto {
            // Auto is running on a default model (orchestrator unavailable).
            let combined = NSMutableAttributedString(attributedString: text)
            combined.append(NSAttributedString(
                string: " ⚠︎",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.systemOrange,
                ]
            ))
            text = combined
        }
        if showBadge {
            let combined = NSMutableAttributedString(attributedString: text)
            combined.append(NSAttributedString(
                string: " II",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .heavy),
                    .baselineOffset: 2,
                    .foregroundColor: NSColor.systemYellow,
                ]
            ))
            text = combined
        }
        button.attributedTitle = text
        button.appearsDisabled = model.offline
        button.toolTip = model.offline
            ? "Substation — daemon offline (\(model.baseURL))"
            : "Substation — \(model.stateLabel) (\(model.baseURL))"
    }

    // MARK: Click handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || (event?.modifierFlags.contains(.control) ?? false)
        if rightClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        add("Open Dashboard", #selector(openDashboard))
        menu.addItem(.separator())
        add("Pause Routing", #selector(pauseRouting))
        add("Resume Routing", #selector(resumeRouting))
        add("Reload Config", #selector(reloadConfig))
        add("Restart Engines", #selector(restartEngines))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled() ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        add("Set Daemon URL…", #selector(setDaemonURL))
        add("Quit Substation", #selector(quit), key: "q")
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openDashboard() {
        guard let url = URL(string: model.baseURL + "/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func pauseRouting() {
        model.pauseRouting()
    }

    @objc private func restartEngines() {
        model.restartAllEngines()
    }

    @objc private func resumeRouting() {
        model.resumeRouting()
    }

    @objc private func reloadConfig() {
        model.reloadConfig()
    }

    @objc private func toggleLoginItem() {
        let next = !LaunchAtLogin.isEnabled()
        if let err = LaunchAtLogin.setEnabled(next) {
            let a = NSAlert(); a.messageText = "Start at Login"; a.informativeText = err
            a.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
        buildMenu()
    }

    @objc private func setDaemonURL() {
        let alert = NSAlert()
        alert.messageText = "Set Daemon URL"
        alert.informativeText = "Overrides SUBSTATION_URL. Leave empty to clear the override."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Settings.storedBaseURLOverride()
            .isEmpty ? model.baseURL : Settings.storedBaseURLOverride()
        field.placeholderString = "http://127.0.0.1:8800"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.setBaseURLOverride(field.stringValue)
        model.reloadBase()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
