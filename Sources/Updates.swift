import SwiftUI
import Sparkle

/// Software updates via Sparkle. Redraft checks its feed about once a day.
/// Instead of interrupting with a window, a found update shows as a quiet
/// "Update available" pill in the top bar; clicking it opens Sparkle's update
/// window (release notes, Install). With "Automatically download and install"
/// on, updates install on quit with no prompt.
@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updates()

    /// The version waiting to be installed, when there is one.
    @Published private(set) var available: String?

    /// Sparkle's standard windows, behind a driver that smooths the timing
    /// of "Checking for updates…" (see SmoothUserDriver).
    private lazy var driver = SmoothUserDriver(inner: SPUStandardUserDriver(hostBundle: .main, delegate: self))

    private(set) lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)

    func start() {
        do { try updater.start() } catch { NSLog("Redraft updates couldn't start: %@", String(describing: error)) }
    }

    func checkForUpdates() { updater.checkForUpdates() }

    #if DEBUG
    /// Debug builds can test against a local feed: REDRAFT_FEED=file:///…/appcast.xml
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["REDRAFT_FEED"]
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Redraft update check failed: %@", String(describing: error))
    }
    #endif

    // MARK: Gentle reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show its window only when you asked (Check for Updates…);
    /// for background checks, Redraft shows its own pill instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            if !handleShowingUpdate && !state.userInitiated { self.available = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.available = nil }
    }
}

/// The quiet top-bar notice for a waiting update.
struct UpdatePill: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        if let version = updates.available {
            Button {
                updates.checkForUpdates()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10.5))
                    Text("Update \(version)")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accent.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("Redraft \(version) is available. Click to see what's new and install.")
            .transition(.opacity)
        }
    }
}

/// Settings → Updates.
struct UpdatesSection: View {
    @State private var autoCheck = Updates.shared.updater.automaticallyChecksForUpdates
    @State private var autoInstall = Updates.shared.updater.automaticallyDownloadsUpdates

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $autoCheck)
                .onChange(of: autoCheck) { _, on in Updates.shared.updater.automaticallyChecksForUpdates = on }
                .pointingHandOnHover()
            Toggle("Download and install updates automatically", isOn: $autoInstall)
                .onChange(of: autoInstall) { _, on in Updates.shared.updater.automaticallyDownloadsUpdates = on }
                .pointingHandOnHover()
                .disabled(!autoCheck)
            LabeledContent {
                Button("Check Now") { Updates.shared.checkForUpdates() }
                .pointingHandOnHover()
            } label: {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            }
        }
    }
}

/// Sparkle's standard update windows with calmer timing for a manual check:
/// - "Checking for updates…" only appears if the check takes longer than
///   half a second, so a quick answer goes straight to the result.
/// - Once it has appeared, it stays at least a second, so it never blinks.
/// Everything else passes straight through to Sparkle.
@MainActor
final class SmoothUserDriver: NSObject, SPUUserDriver {
    private let inner: SPUStandardUserDriver
    private static let delay: TimeInterval = 0.5
    private static let minimumVisible: TimeInterval = 1.0

    private var pendingCheckWindow: DispatchWorkItem?
    private var checkWindowShownAt: Date?
    private var held: [() -> Void] = []
    private var flushScheduled = false

    init(inner: SPUStandardUserDriver) { self.inner = inner }

    private func trace(_ what: String) {
        #if DEBUG
        // REDRAFT_UPDATE_TRACE=<file>: append timestamped steps, for timing tests.
        if let path = ProcessInfo.processInfo.environment["REDRAFT_UPDATE_TRACE"] {
            let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, what)
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        }
        #endif
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        trace("check started")
        checkWindowShownAt = nil
        let show = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCheckWindow = nil
            self.checkWindowShownAt = Date()
            self.trace("checking window shown")
            self.inner.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
        pendingCheckWindow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: show)
    }

    /// Runs the next step now, or after the checking window's minimum time.
    private func pass(_ step: @escaping () -> Void) {
        trace("result arrived")
        if let pending = pendingCheckWindow {
            // Answered before the checking window appeared: skip it entirely.
            pending.cancel()
            pendingCheckWindow = nil
            step()
            return
        }
        guard let shownAt = checkWindowShownAt else {
            if held.isEmpty { step() } else { held.append(step) }
            return
        }
        held.append(step)
        guard !flushScheduled else { return }
        flushScheduled = true
        let remaining = max(0, Self.minimumVisible - Date().timeIntervalSince(shownAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.checkWindowShownAt = nil
            let steps = self.held
            self.held = []
            self.trace("result shown after minimum time")
            steps.forEach { $0() }
        }
    }

    // MARK: Pass-through

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        inner.show(request, reply: reply)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pass { self.inner.showUpdateFound(with: appcastItem, state: state, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        pass { self.inner.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        pass { self.inner.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        pass { self.inner.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        pass { self.inner.showUpdaterError(error, acknowledgement: acknowledgement) }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        pass { self.inner.showDownloadInitiated(cancellation: cancellation) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        pass { self.inner.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        pass { self.inner.showDownloadDidReceiveData(ofLength: length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        pass { self.inner.showDownloadDidStartExtractingUpdate() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        pass { self.inner.showExtractionReceivedProgress(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pass { self.inner.showReady(toInstallAndRelaunch: reply) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        pass { self.inner.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        pass { self.inner.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    }

    func showUpdateInFocus() {
        pass { self.inner.showUpdateInFocus() }
    }

    func dismissUpdateInstallation() {
        pass { self.inner.dismissUpdateInstallation() }
    }
}
