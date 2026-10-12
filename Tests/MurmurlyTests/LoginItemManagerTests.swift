import XCTest
@testable import Murmurly

final class LoginItemManagerTests: XCTestCase {
    private struct Case {
        let name: String
        let desired: Bool
        let currentPath: String
        let status: LoginItemManager.ServiceStatus
        let lastPath: String?
        let isRunningTests: Bool
        let expected: LoginItemManager.ReconciliationAction
    }

    func testReconciliationDecisionTable() {
        let installed = "/Users/test/Applications/Murmurly.app"
        let systemInstalled = "/Applications/Murmurly.app"
        let derived = "/Users/test/Library/Developer/Xcode/DerivedData/Murmurly/Build/Products/Debug/Murmurly.app"
        let oldDerived = "/Users/test/Library/Developer/Xcode/DerivedData/Old/Build/Products/Debug/Murmurly.app"
        let cases: [Case] = [
            Case(
                name: "temporary build never registers",
                desired: true,
                currentPath: derived,
                status: .notRegistered,
                lastPath: nil,
                isRunningTests: false,
                expected: .none
            ),
            Case(
                name: "temporary build never unregisters installed copy",
                desired: false,
                currentPath: derived,
                status: .enabled,
                lastPath: installed,
                isRunningTests: false,
                expected: .none
            ),
            Case(
                name: "tests suppress registration",
                desired: true,
                currentPath: installed,
                status: .notRegistered,
                lastPath: nil,
                isRunningTests: true,
                expected: .none
            ),
            Case(
                name: "desired on registers missing service",
                desired: true,
                currentPath: installed,
                status: .notRegistered,
                lastPath: nil,
                isRunningTests: false,
                expected: .register
            ),
            Case(
                name: "not found retries registration",
                desired: true,
                currentPath: installed,
                status: .notFound,
                lastPath: installed,
                isRunningTests: false,
                expected: .register
            ),
            Case(
                name: "desired off unregisters enabled service",
                desired: false,
                currentPath: installed,
                status: .enabled,
                lastPath: installed,
                isRunningTests: false,
                expected: .unregister
            ),
            Case(
                name: "desired off unregisters approval-pending service",
                desired: false,
                currentPath: installed,
                status: .requiresApproval,
                lastPath: installed,
                isRunningTests: false,
                expected: .unregister
            ),
            Case(
                name: "desired off leaves absent service alone",
                desired: false,
                currentPath: installed,
                status: .notRegistered,
                lastPath: installed,
                isRunningTests: false,
                expected: .none
            ),
            Case(
                name: "unchanged enabled registration is idempotent",
                desired: true,
                currentPath: installed,
                status: .enabled,
                lastPath: installed,
                isRunningTests: false,
                expected: .none
            ),
            Case(
                name: "requires approval is not re-registered repeatedly",
                desired: true,
                currentPath: installed,
                status: .requiresApproval,
                lastPath: installed,
                isRunningTests: false,
                expected: .none
            ),
            Case(
                name: "changed enabled path is re-registered",
                desired: true,
                currentPath: installed,
                status: .enabled,
                lastPath: oldDerived,
                isRunningTests: false,
                expected: .reregister
            ),
            Case(
                name: "changed approval-pending path is re-registered",
                desired: true,
                currentPath: installed,
                status: .requiresApproval,
                lastPath: oldDerived,
                isRunningTests: false,
                expected: .reregister
            ),
            Case(
                name: "copy dragged into /Applications registers",
                desired: true,
                currentPath: systemInstalled,
                status: .notRegistered,
                lastPath: nil,
                isRunningTests: false,
                expected: .register
            ),
            Case(
                name: "/Applications copy re-registers a registration made elsewhere",
                desired: true,
                currentPath: systemInstalled,
                status: .enabled,
                lastPath: installed,
                isRunningTests: false,
                expected: .reregister
            ),
            Case(
                name: "/Applications copy honours desired off",
                desired: false,
                currentPath: systemInstalled,
                status: .enabled,
                lastPath: systemInstalled,
                isRunningTests: false,
                expected: .unregister
            ),
            Case(
                name: "unknown provenance is migrated once",
                desired: true,
                currentPath: installed,
                status: .enabled,
                lastPath: nil,
                isRunningTests: false,
                expected: .reregister
            )
        ]

        for item in cases {
            XCTAssertEqual(
                LoginItemManager.reconciliationAction(
                    desired: item.desired,
                    currentBundlePath: item.currentPath,
                    installedBundlePaths: [installed, systemInstalled],
                    status: item.status,
                    lastRegisteredPath: item.lastPath,
                    isRunningTests: item.isRunningTests
                ),
                item.expected,
                item.name
            )
        }
    }
}
