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
