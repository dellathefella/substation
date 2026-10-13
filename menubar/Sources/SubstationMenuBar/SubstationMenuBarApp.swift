import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(model: model)
        model.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

@main
struct SubstationMenuBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar accessory: no Dock icon, no menu bar title.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
