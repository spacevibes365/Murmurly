import Combine
import Foundation
import ServiceManagement

/// Reconciles the user's persisted preference with the system's actual login-item state.
/// All ServiceManagement access stays on the main actor; the decision table is pure.
@MainActor
final class LoginItemManager: ObservableObject {
    enum ServiceStatus: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    enum ReconciliationAction: Equatable, Sendable {
        case none
        case register
        case unregister
        case reregister
    }

    @Published private(set) var serviceStatus: ServiceStatus?
    @Published private(set) var errorMessage: String?

    let isInstalledBundle: Bool

    private static let lastRegisteredPathKey = "loginItem.lastRegisteredBundlePath"
    private let defaults: UserDefaults
    private let currentBundlePath: String
    private let installedBundlePaths: [String]
    private let isRunningTests: Bool

    /// A downloaded DMG is dragged into /Applications; `scripts/install.sh` uses
    /// ~/Applications so a source build needs no admin rights. Both are real installs.
    nonisolated static func defaultInstalledBundlePaths(appName: String) -> [String] {
        [NSHomeDirectory() + "/Applications/" + appName, "/Applications/" + appName]
    }

    init(
        defaults: UserDefaults = TestIsolation.settingsDefaults(),
        bundleURL: URL = Bundle.main.bundleURL,
        installedBundlePaths: [String]? = nil,
        processInfo: ProcessInfo = .processInfo
    ) {
        self.defaults = defaults
        currentBundlePath = Self.normalizedPath(bundleURL.path)
        self.installedBundlePaths = (installedBundlePaths
            ?? Self.defaultInstalledBundlePaths(appName: bundleURL.lastPathComponent))
            .map(Self.normalizedPath)
        isInstalledBundle = self.installedBundlePaths.contains(currentBundlePath)
        isRunningTests = TestIsolation.classify(processInfo: processInfo).testProcess
    }

    /// Returns the one system mutation needed to converge, if any. A build outside
    /// the install locations must never disturb a valid registration owned by the
    /// installed copy, even when both bundles share an identifier and defaults.
    nonisolated static func reconciliationAction(
        desired: Bool,
        currentBundlePath: String,
        installedBundlePaths: [String],
        status: ServiceStatus,
        lastRegisteredPath: String?,
        isRunningTests: Bool
    ) -> ReconciliationAction {
        guard !isRunningTests else { return .none }

        let current = normalizedPath(currentBundlePath)
        guard installedBundlePaths.map(normalizedPath).contains(current) else { return .none }

        if !desired {
            switch status {
            case .enabled, .requiresApproval:
                return .unregister
            case .notRegistered, .notFound:
                return .none
            }
        }

        switch status {
        case .notRegistered, .notFound:
            return .register
        case .enabled, .requiresApproval:
            guard let lastRegisteredPath,
                  normalizedPath(lastRegisteredPath) == current else {
                // Missing provenance is treated as a one-time migration: the
                // existing registration may still point into DerivedData.
                return .reregister
            }
            return .none
        }
    }

    func activate(desired: Bool) {
        reconcile(desired: desired)
    }

    func reconcile(desired: Bool) {
        errorMessage = nil

        // Do not even inspect SMAppService from a temporary or test bundle. The
        // same bundle identifier may refer to the installed app's registration.
        guard isInstalledBundle, !isRunningTests else {
            serviceStatus = nil
            return
        }

        let service = SMAppService.mainApp
        let status = Self.serviceStatus(from: service.status)
        serviceStatus = status
        let action = Self.reconciliationAction(
            desired: desired,
            currentBundlePath: currentBundlePath,
            installedBundlePaths: installedBundlePaths,
            status: status,
            lastRegisteredPath: defaults.string(forKey: Self.lastRegisteredPathKey),
            isRunningTests: false
        )

        do {
            switch action {
            case .none:
                if !desired {
                    switch status {
                    case .notRegistered, .notFound:
                        defaults.removeObject(forKey: Self.lastRegisteredPathKey)
                    case .enabled, .requiresApproval:
                        break
                    }
                }
            case .register:
                try service.register()
                defaults.set(currentBundlePath, forKey: Self.lastRegisteredPathKey)
                AppLog.info("login-item", "registered " + currentBundlePath)
            case .unregister:
                try service.unregister()
                defaults.removeObject(forKey: Self.lastRegisteredPathKey)
                AppLog.info("login-item", "unregistered")
            case .reregister:
                try service.unregister()
                defaults.removeObject(forKey: Self.lastRegisteredPathKey)
                try service.register()
                defaults.set(currentBundlePath, forKey: Self.lastRegisteredPathKey)
                AppLog.info("login-item", "re-registered " + currentBundlePath)
            }
            serviceStatus = Self.serviceStatus(from: service.status)
        } catch {
            serviceStatus = Self.serviceStatus(from: service.status)
            errorMessage = error.localizedDescription
            AppLog.error("login-item", "reconcile failed: " + error.localizedDescription)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Reads the system's state again without changing it: the person may
    /// have just approved or turned off the login item in System Settings,
    /// and that decision is theirs to keep.
    func refreshStatus() {
        guard isInstalledBundle, !isRunningTests else { return }
        serviceStatus = Self.serviceStatus(from: SMAppService.mainApp.status)
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func serviceStatus(from status: SMAppService.Status) -> ServiceStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
}
