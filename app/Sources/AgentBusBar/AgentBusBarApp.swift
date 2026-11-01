import AppKit
import SwiftUI

@main
struct AgentBusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BusStore()

    var body: some Scene {
        MenuBarExtra {
            BusPanel(store: store)
        } label: {
            // The badge counts what waits on the user: asks, plus stuck work.
            let n = store.badgeCount
            Image(systemName: store.error == nil ? "bus" : "exclamationmark.triangle")
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Menu bar only: no Dock icon, no app menu. The bundle's LSUIElement does
    // the same; this covers `swift run`.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // `AgentBusBar --render <png> [activity|work|seats]` draws the panel to an
        // image and exits: a way to check the UI without opening the menu.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let want = args.count > i + 2 ? args[i + 2] : "attention"
            let tab = Tab.allCases.first { $0.rawValue.lowercased().contains(want) }
            Task { @MainActor in
                let store = BusStore()
                try? await Task.sleep(for: .seconds(3))
                let renderer = ImageRenderer(content: BusPanel(store: store, tab: tab ?? .attention, forImage: true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
