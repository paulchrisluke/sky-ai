import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    let state: MenuBarState

    private let sourceManager: SourceManager
    private let setSyncEnabledHandler: @MainActor (Bool) -> Void
    private let openDashboardHandler: () -> Void
    private let preferencesHandler: () -> Void

    init(
        sourceManager: SourceManager,
        setSyncEnabled: @escaping @MainActor (Bool) -> Void,
        openDashboard: @escaping () -> Void,
        preferences: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.state = MenuBarState()
        self.sourceManager = sourceManager
        self.setSyncEnabledHandler = setSyncEnabled
        self.openDashboardHandler = openDashboard
        self.preferencesHandler = preferences
        super.init()
        setup()
    }

    private func setup() {
        if let button = statusItem.button {
            button.title = " Blawby"
            button.imagePosition = .imageLeading
            if let image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "Blawby") {
                image.isTemplate = true
                button.image = image
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let popoverView = MenuBarPopoverView(
            sourceManager: sourceManager,
            state: state,
            onClose: { [weak self] in
                self?.popover.performClose(nil)
            },
            onToggleSync: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.setSyncEnabledHandler(!self.state.syncActivated)
                }
            },
            onOpenDashboard: { [weak self] in
                self?.popover.performClose(nil)
                self?.openDashboardHandler()
            },
            onOpenPreferences: { [weak self] in
                self?.popover.performClose(nil)
                self?.preferencesHandler()
            }
        )

        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.behavior = .transient
    }

    func update(
        lastSync: String,
        connection: String,
        syncActivated: Bool,
        sources: [ConnectedSource]
    ) {
        state.connection = connection
        state.lastSync = lastSync
        state.syncActivated = syncActivated

        let topStatus = topStatusTitle(for: sources)
        updateStatusIcon(connection: connection, topStatus: topStatus)
    }

    private func topStatusTitle(for sources: [ConnectedSource]) -> String {
        let enabled = sources.filter(\.enabled)
        if enabled.isEmpty {
            return "⏸ No sources enabled"
        }

        let errorCount = enabled.filter { $0.status == "error" }.count
        if errorCount > 0 {
            return "⚠ \(errorCount) errors"
        }

        let syncing = enabled.contains { $0.status == "syncing" }
        if syncing {
            let x = enabled.reduce(0) { $0 + max(0, $1.totalSynced) }
            let y = enabled.reduce(0) { $0 + max(0, $1.totalEstimated) }
            return "Syncing… \(formatNumber(x)) / \(formatNumber(y))"
        }

        if enabled.allSatisfy({ $0.status == "current" }) {
            return "✓ All current"
        }

        let paused = sources.filter { !$0.enabled }.count
        if paused > 0 {
            return "⏸ \(paused) sources paused"
        }

        return "Syncing…"
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func updateStatusIcon(connection: String, topStatus: String) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        if topStatus.hasPrefix("⚠") {
            symbolName = "exclamationmark.triangle.fill"
        } else if topStatus.hasPrefix("Syncing") {
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
        } else if connection.lowercased().hasPrefix("connected") {
            symbolName = "checkmark.circle.fill"
        } else if connection.lowercased().hasPrefix("reconnecting") || connection.lowercased().hasPrefix("connecting") {
            symbolName = "arrow.triangle.2.circlepath"
        } else {
            symbolName = "wifi.exclamationmark"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Blawby") {
            image.isTemplate = true
            button.image = image
            button.title = " Blawby"
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let button = statusItem.button {
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
