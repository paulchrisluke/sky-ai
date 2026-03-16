import XCTest

final class ArchitectureGuardrailsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BlawbyAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // agent-mac
    }

    func testMenuBarPopoverHasNoLegacyCloseControl() throws {
        let file = repoRoot.appendingPathComponent("Sources/BlawbyAgent/App/MenuBarPopoverView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("onClose"), "MenuBarExtra should not carry legacy popover close handlers.")
        XCTAssertFalse(text.contains("systemName: \"xmark\""), "Close button should be removed in MenuBarExtra flow.")
        XCTAssertFalse(
            text.contains("controlBackgroundColor"),
            "MenuBarPopoverView should avoid custom control backgrounds so system material can render naturally."
        )
        XCTAssertFalse(
            text.contains("PlainButtonStyle"),
            "MenuBarPopoverView should avoid forcing plain button chrome over system styling."
        )
    }

    func testMainUIStateIsMainActorIsolated() throws {
        let file = repoRoot.appendingPathComponent("Sources/BlawbyAgent/App/MenuBarPopoverView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("@MainActor\nclass MenuBarState"), "MenuBarState should remain main-actor isolated.")
    }

    func testViewLayerAvoidsAppKitImport() throws {
        let files = [
            "Sources/BlawbyAgent/App/BlawbyAgentApp.swift",
            "Sources/BlawbyAgent/App/MenuBarPopoverView.swift",
            "Sources/BlawbyAgent/App/DashboardView.swift",
            "Sources/BlawbyAgent/App/PreferencesView.swift"
        ]
        for path in files {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("import AppKit"), "\(path) should stay SwiftUI-only.")
        }
    }

    func testRuntimeServicesAvoidSwiftUIImport() throws {
        let files = [
            "Sources/BlawbyAgent/App/AppSession.swift",
            "Sources/BlawbyAgent/App/AppStartupComposer.swift",
            "Sources/BlawbyAgent/App/SyncRuntimeController.swift"
        ]
        for path in files {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("import SwiftUI"), "\(path) should remain non-view runtime code.")
        }
    }

    func testDashboardUsesSystemToolbarAndAvoidsCustomBackgroundChrome() throws {
        let file = repoRoot.appendingPathComponent("Sources/BlawbyAgent/App/DashboardView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(".toolbar"), "Dashboard should expose actions via native toolbar APIs.")
        XCTAssertTrue(text.contains(".searchable("), "Dashboard should keep native searchable placement.")
        XCTAssertFalse(text.contains(".background("), "Dashboard should avoid custom background chrome overlays.")
    }

    func testUIDateDisplayUsesDateValuesInsteadOfRawISOStrings() throws {
        let appSession = repoRoot.appendingPathComponent("Sources/BlawbyAgent/App/AppSession.swift")
        let appSessionText = try String(contentsOf: appSession, encoding: .utf8)
        XCTAssertFalse(
            appSessionText.contains("ISO8601DateFormatter()"),
            "AppSession should avoid formatting UI timestamps as raw ISO strings."
        )

        let popover = repoRoot.appendingPathComponent("Sources/BlawbyAgent/App/MenuBarPopoverView.swift")
        let popoverText = try String(contentsOf: popover, encoding: .utf8)
        XCTAssertTrue(popoverText.contains("@Published var lastSync: Date?"), "Menu UI state should store Date values.")
    }

    func testLegacyLifecycleFilesRemainDeleted() {
        let deletedPaths = [
            "Sources/BlawbyAgent/main.swift",
            "Sources/BlawbyAgent/App/AppDelegate.swift",
            "Sources/BlawbyAgent/App/AppUIController.swift",
            "Sources/BlawbyAgent/App/MenuBarController.swift",
            "Sources/BlawbyAgent/App/PreferencesWindowController.swift"
        ]
        for path in deletedPaths {
            let exists = FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(path).path)
            XCTAssertFalse(exists, "\(path) should stay deleted after scene migration.")
        }
    }
}
