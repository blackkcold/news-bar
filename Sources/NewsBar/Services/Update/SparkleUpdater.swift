import AppKit
import Combine
import Sparkle
import os

/// Sparkle-backed update controller.
///
/// Sparkle owns the parts that must not be re-implemented: the appcast
/// fetch, EdDSA verification, delta application, the installer helper and
/// the standard update window. This type only mirrors the states the menu
/// bar badge and the settings pane need, so the UI stays declarative.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject {

    private static let log = Logger(subsystem: "com.newsbar.app", category: "updates")

    // MARK: - State

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        /// An update was found. Sparkle may already be downloading it in the
        /// background when automatic downloads are on.
        case available(String)
        /// Downloaded and waiting for the next quit (or an explicit install).
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    /// Sparkle needs `SUFeedURL` and `SUPublicEDKey` in the main bundle.
    /// `swift run` and the test runner have neither, so the updater stays
    /// inert there instead of showing Sparkle's misconfiguration alert.
    static var isConfigured: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(feed ?? "").isEmpty && !(key ?? "").isEmpty
    }

    private var idleResetTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []

    /// The app always starts at `.idle`. Rendering tests and previews use this
    /// to exercise the badge without driving Sparkle through a real cycle.
    init(initialState: State = .idle) {
        super.init()
        state = initialState
    }

    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()

    private var updater: SPUUpdater { controller.updater }

    // MARK: - Lifecycle

    /// Starts Sparkle's scheduler. Safe to call more than once.
    func start() {
        guard Self.isConfigured else {
            Self.log.info("Sparkle not configured in this bundle; updater disabled")
            return
        }
        guard !started else { return }
        started = true
        // The update window speaks whatever the process resolved at launch.
        // This line is the fastest way to confirm a shipped build picked the
        // language the person chose (see ProcessLanguage).
        let localization = Bundle(for: SPUStandardUserDriver.self).preferredLocalizations.first ?? "unknown"
        Self.log.info("Sparkle UI localization: \(localization, privacy: .public)")
        controller.startUpdater()
        observeUpdater()
        refreshSettingsMirror()
    }

    private var started = false

    func checkForUpdates() {
        guard Self.isConfigured else { return }
        start()
        guard updater.canCheckForUpdates else {
            Self.log.info("Check ignored: Sparkle is busy")
            return
        }
        idleResetTask?.cancel()
        state = .checking
        // A menu-bar app has no Dock icon; bring the update window forward
        // before Sparkle opens it so it is never born behind another app.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - Settings

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard Self.isConfigured else { return }
        start()
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard Self.isConfigured else { return }
        start()
        updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = enabled
    }

    var currentVersion: String { AppVersion.current }

    private func observeUpdater() {
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.automaticallyChecksForUpdates
                Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = value }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.automaticallyDownloadsUpdates
                Task { @MainActor [weak self] in self?.automaticallyDownloadsUpdates = value }
            },
        ]
    }

    private func refreshSettingsMirror() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    // MARK: - State helpers

    private func showTransient(_ state: State, seconds: UInt64 = 3) {
        idleResetTask?.cancel()
        self.state = state
        idleResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state == state else { return }
                self.state = .idle
            }
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdater: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        idleResetTask?.cancel()
        state = .available(item.displayVersionString)
        Self.log.info("Update available: \(item.displayVersionString, privacy: .public)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Sparkle reports "no update" through the error channel too.
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
            if case .checking = state {
                showTransient(.upToDate(AppVersion.current))
            } else if case .available = state {
                // The offered version was skipped or withdrawn; a stale
                // "update available" badge would be a lie.
                state = .idle
            }
            return
        }

        // Background checks stay silent. Only a check the person asked for
        // may put an error in the header.
        Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        if case .checking = state {
            state = .failed(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        idleResetTask?.cancel()
        state = .ready(item.displayVersionString)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state updateState: SPUUserUpdateState
    ) {
        // "Skip this version" means the badge must stop advertising it now,
        // not in 24 hours when the next scheduled cycle runs.
        if choice == .skip {
            idleResetTask?.cancel()
            state = .idle
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.log.error("Update aborted: \(error.localizedDescription, privacy: .public)")
        if case .checking = state {
            state = .failed(error.localizedDescription)
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            if nsError.code == Int(SUError.noUpdateError.rawValue) {
                if case .checking = state {
                    showTransient(.upToDate(AppVersion.current))
                }
            } else {
                Self.log.error("Update cycle failed: \(error.localizedDescription, privacy: .public)")
                if case .checking = state {
                    state = .failed(error.localizedDescription)
                }
            }
        } else if case .checking = state {
            // A cycle that ends without an item means the user is current.
            showTransient(.upToDate(AppVersion.current))
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {

    /// A menu-bar app has no Dock icon, so a scheduled alert that Sparkle
    /// raises on its own is easy to miss. The popover badge is the gentle
    /// reminder: a scheduled check only lights it up, and Sparkle's window
    /// opens when the person actually asks for it (or right after launch).
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Near launch the person is already looking at the app; elsewhere the
        // badge handles it without stealing focus from the current window.
        immediateFocus
    }

    /// Sparkle is about to show a window or alert. A menu-bar app runs with
    /// the `.accessory` policy, so it must temporarily become a regular app
    /// or the update window cannot become key and never reaches the front.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.setActivationPolicy(.accessory)
    }
}
