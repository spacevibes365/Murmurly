import AppKit
import SwiftUI
import XCTest
@testable import Murmurly

@MainActor
final class AppWindowControllerTests: XCTestCase {
    /// A panel's owner is the window of the view it was asked from, read at
    /// the moment of the action: another window key at that moment does not
    /// take it, and a view in a sheet answers with the window the sheet is on.
    func testAViewsOwnWindowOwnsItsPanels() async throws {
        let own = makeWindow()
        let other = makeWindow()
        own.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let anchor = WindowAnchor()
        own.contentView = NSHostingView(rootView: Color.clear.frame(width: 80, height: 40).background(WindowAnchor.Reader(anchor: anchor)))
        own.orderFrontRegardless()
        other.makeKeyAndOrderFront(nil)
        defer {
            own.orderOut(nil)
            other.orderOut(nil)
        }
        try await until { anchor.window != nil }
        XCTAssertFalse(NSApp.keyWindow === own, "the view's own window was key — the check proves nothing")
        XCTAssertTrue(anchor.window === own, "the panel would go on \(String(describing: anchor.window)), not the view's window")

        let sheet = makeWindow()
        sheet.isReleasedWhenClosed = false
        let inSheet = WindowAnchor()
        sheet.contentView = NSHostingView(rootView: Color.clear.frame(width: 80, height: 40).background(WindowAnchor.Reader(anchor: inSheet)))
        own.beginSheet(sheet, completionHandler: nil)
        defer { own.endSheet(sheet) }
        try await until { inSheet.window != nil }
        XCTAssertTrue(inSheet.window === own, "a view in a sheet answered with \(String(describing: inSheet.window)), not the sheet's window")
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never came")
    }

    func testVisibleWindowCountIncludesTwoWindowsButNeverPanel() {
        let first = makeWindow()
        let second = makeWindow()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
            panel.orderOut(nil)
        }

        first.orderFrontRegardless()
        second.orderFrontRegardless()
        panel.orderFrontRegardless()
        let windows = [first, second, panel]

        XCTAssertEqual(AppWindowController.visibleRealWindowCount(in: windows), 2)
        second.orderOut(nil)
        XCTAssertEqual(AppWindowController.visibleRealWindowCount(in: windows), 1)
        first.orderOut(nil)
        XCTAssertEqual(AppWindowController.visibleRealWindowCount(in: windows), 0)
        XCTAssertTrue(panel.isVisible)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
