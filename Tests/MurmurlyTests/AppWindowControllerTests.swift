import AppKit
import XCTest
@testable import Murmurly

@MainActor
final class AppWindowControllerTests: XCTestCase {
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
