import AppKit
import FolioScraperCore
import Foundation
import SwiftUI

struct QueuedJob: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var displayText: String {
        url.absoluteString
    }
}

/// Resolves the first result and cancels the losing work without waiting for it to cooperate.
private final class TimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let alreadyResolved = continuation == nil
        if !alreadyResolved {
            self.tasks = tasks
        }
        lock.unlock()

        if alreadyResolved {
            tasks.forEach { $0.cancel() }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = continuation
        let tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    private struct ScrapeTimeoutError: LocalizedError {
        let seconds: Int

        var errorDescription: String? {
            "Site scrape timed out after \(seconds / 60) minutes"
        }
    }

    let maxImageOptions = [200, 400, 800, 1_500]
    private let cliCommandName = "folioscraper"
    private let bundledCLIName = "folioscraper-cli"
    private let cliInstallPath = "/usr/local/bin/folioscraper"
    private let installedBundlePathKey = "installedCLIAppBundlePath"
    private let failedPromptBundlePathKey = "failedCLIInstallPromptBundlePath"
    private let queuedJobURLsKey = "queuedJobURLs"
    private let currentJobURLKey = "currentJobURL"
    private let selectedMaxImagesKey = "selectedMaxImages"
    private let saveDetailsKey = "saveDetails"
    private let downloadSmallImagesKey = "downloadSmallImages"
    private let downloadVideosKey = "downloadVideos"
    private let organiseImagesBySourcePageKey = "organiseImagesBySourcePage"
    private let interruptedRetryCountsKey = "interruptedJobRetryCounts"
    private let maxRecoveredAutoRetries = 1
    private let siteTimeout: Duration = .seconds(1800)

    @Published var inputURL = ""
    @Published var selectedMaxImages = 200 {
        didSet { persistOptionState() }
    }
    @Published var saveDetails = true {
        didSet { persistOptionState() }
    }
    @Published var downloadSmallImages = false {
        didSet { persistOptionState() }
    }
    @Published var downloadVideos = true {
        didSet { persistOptionState() }
    }
    @Published var organizeImagesBySourcePage = true {
        didSet { persistOptionState() }
    }
    @Published private(set) var queuedJobs: [QueuedJob] = [] {
        didSet {
            guard !isRestoringQueueState else { return }
            persistQueueState()
        }
    }
    @Published private(set) var currentJob: QueuedJob? {
        didSet {
            guard !isRestoringQueueState else { return }
            persistQueueState()
        }
    }
    @Published private(set) var logEntries: [String] = ["Ready. Add a site to begin."]
    @Published private(set) var statusText = "Ready"
    @Published private(set) var statusColor: Color = .green
    @Published private(set) var isRunning = false
    @Published private(set) var savedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var foundCount = 0

    private let scraper = PortfolioScraperService()
    private var configuredWindowNumbers = Set<Int>()
    private var attemptedCLISetup = false
    private var scrapeTask: Task<Void, Never>?
    private var stopRequested = false
    private var isRestoringOptionState = false
    private var isRestoringQueueState = false
    private var shouldAutoStartRestoredQueue = true

    init() {
        restoreOptionState()
        restoreQueueState()
    }

    func configure(window: NSWindow) {
        guard configuredWindowNumbers.insert(window.windowNumber).inserted else {
            return
        }

        window.title = "FolioArchiver"
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 980, height: 620))
        window.minSize = NSSize(width: 980, height: 620)
        window.maxSize = NSSize(width: 980, height: 620)
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        installCLIWrapperIfNeeded()
    }

    var queueSummary: String {
        if let _ = currentJob {
            return "1 running, \(queuedJobs.count) pending"
        }

        if queuedJobs.isEmpty {
            return "No queued sites."
        }

        return "\(queuedJobs.count) pending"
    }

    func enqueueCurrentInput() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        inputURL = ""
        enqueue(urlString: trimmed)
    }

    private func enqueue(urlString: String) {
        guard let normalizedURL = normalizedURL(from: urlString) else {
            appendLog("Ignored invalid URL: \(urlString)")
            return
        }

        clearInterruptedRetryCount(for: normalizedURL)
        queuedJobs.append(QueuedJob(url: normalizedURL))
        appendLog("Queued \(normalizedURL.absoluteString)")
        startNextJobIfNeeded()
    }

    private func normalizedURL(from string: String) -> URL? {
        if let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
            return url
        }

        return URL(string: "https://\(string)")
    }

    private func startNextJobIfNeeded() {
        guard !isRunning, !queuedJobs.isEmpty else { return }

        let nextJob = queuedJobs.removeFirst()
        currentJob = nextJob
        isRunning = true
        stopRequested = false
        statusText = "Scraping"
        statusColor = .blue
        appendLog("Scraping \(nextJob.displayText)")

        scrapeTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.runScrapeWithTimeout(for: nextJob) {
                    try await self.scraper.scrape(
                        startURL: nextJob.url,
                        maxImages: self.selectedMaxImages,
                        outputRoot: nil,
                        saveDetails: self.saveDetails,
                        downloadSmallImages: self.downloadSmallImages,
                        downloadVideos: self.downloadVideos,
                        organizeImagesBySourcePage: self.organizeImagesBySourcePage
                    ) { line in
                        await MainActor.run {
                            self.appendLog(line)
                        }
                    }
                }

                await MainActor.run {
                    self.finishSuccess(result: result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishStopped(for: nextJob)
                }
            } catch {
                await MainActor.run {
                    self.finishFailure(for: nextJob, error: error)
                }
            }
        }
    }

    private func finishSuccess(result: ScrapeResult) {
        scrapeTask = nil
        stopRequested = false
        isRunning = false
        clearInterruptedRetryCount(for: currentJob?.url)
        currentJob = nil
        statusText = "Finished \(result.studio)"
        statusColor = .green
        foundCount += result.foundCandidates
        savedCount += result.downloaded.count
        failedCount += result.errors

        appendLog("Finished \(result.studio)")
        appendLog("Platform: \(result.platform) | Saved: \(result.downloaded.count) | Too small: \(result.skippedSmall) | Too large: \(result.skippedLarge) | Failed: \(result.errors)")

        NSWorkspace.shared.open(result.outputDirectory)

        if !queuedJobs.isEmpty {
            appendLog("Continuing with \(queuedJobs.count) queued job(s).")
        }

        startNextJobIfNeeded()
    }

    private func finishFailure(for job: QueuedJob, error: Error) {
        scrapeTask = nil
        stopRequested = false
        isRunning = false
        clearInterruptedRetryCount(for: job.url)
        currentJob = nil
        statusText = "Error"
        statusColor = .red
        failedCount += 1
        appendLog("Error for \(job.displayText): \(error.localizedDescription)")

        if queuedJobs.isEmpty {
            showAlert(title: "Scrape failed", message: error.localizedDescription)
        } else {
            appendLog("Skipping to next queued job after failure on \(job.displayText).")
        }

        startNextJobIfNeeded()
    }

    func stopScraping() {
        guard isRunning else { return }

        stopRequested = true
        queuedJobs.removeAll()
        statusText = "Stopping"
        statusColor = .orange
        appendLog("Stopping current scrape and clearing queued jobs.")
        scrapeTask?.cancel()
    }

    private func finishStopped(for job: QueuedJob) {
        scrapeTask = nil
        isRunning = false
        clearInterruptedRetryCount(for: job.url)
        currentJob = nil
        statusText = "Stopped"
        statusColor = .orange

        if stopRequested {
            appendLog("Stopped \(job.displayText)")
        } else {
            appendLog("Cancelled \(job.displayText)")
        }

        stopRequested = false
    }

    func removeQueuedJob(id: UUID) {
        let removedURLs = queuedJobs.filter { $0.id == id }.map(\.url)
        queuedJobs.removeAll { $0.id == id }
        for url in removedURLs {
            clearInterruptedRetryCount(for: url)
        }
    }

    func moveQueuedJob(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = queuedJobs.firstIndex(where: { $0.id == id }),
              let targetIndex = queuedJobs.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let item = queuedJobs.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        queuedJobs.insert(item, at: adjustedTarget)
    }

    private func appendLog(_ line: String) {
        logEntries.append(line)
        logEntries = Array(logEntries.suffix(120))
    }

    private func persistQueueState() {
        let defaults = UserDefaults.standard
        defaults.set(queuedJobs.map { $0.url.absoluteString }, forKey: queuedJobURLsKey)
        defaults.set(currentJob?.url.absoluteString, forKey: currentJobURLKey)
    }

    private func persistOptionState() {
        guard !isRestoringOptionState else { return }

        let defaults = UserDefaults.standard
        defaults.set(selectedMaxImages, forKey: selectedMaxImagesKey)
        defaults.set(saveDetails, forKey: saveDetailsKey)
        defaults.set(downloadSmallImages, forKey: downloadSmallImagesKey)
        defaults.set(downloadVideos, forKey: downloadVideosKey)
        defaults.set(organizeImagesBySourcePage, forKey: organiseImagesBySourcePageKey)
    }

    private func restoreOptionState() {
        let defaults = UserDefaults.standard

        isRestoringOptionState = true
        defer {
            isRestoringOptionState = false
            persistOptionState()
        }

        if defaults.object(forKey: selectedMaxImagesKey) != nil {
            let persistedMaxImages = defaults.integer(forKey: selectedMaxImagesKey)
            if maxImageOptions.contains(persistedMaxImages) {
                selectedMaxImages = persistedMaxImages
            }
        }

        if let value = defaults.persistedBool(forKey: saveDetailsKey) {
            saveDetails = value
        }
        if let value = defaults.persistedBool(forKey: downloadSmallImagesKey) {
            downloadSmallImages = value
        }
        if let value = defaults.persistedBool(forKey: downloadVideosKey) {
            downloadVideos = value
        }
        if let value = defaults.persistedBool(forKey: organiseImagesBySourcePageKey) {
            organizeImagesBySourcePage = value
        }
    }

    private func restoreQueueState() {
        let defaults = UserDefaults.standard
        let persistedQueueURLs = defaults.stringArray(forKey: queuedJobURLsKey) ?? []
        let persistedCurrentURL = defaults.string(forKey: currentJobURLKey)
        let retryCounts = interruptedRetryCounts()

        var restoredJobs: [QueuedJob] = []
        var seenURLs = Set<String>()
        var deferredInterruptedJob: QueuedJob?
        shouldAutoStartRestoredQueue = true

        if let persistedCurrentURL,
           let url = normalizedURL(from: persistedCurrentURL) {
            seenURLs.insert(url.absoluteString)
            let retryCount = retryCounts[url.absoluteString] ?? 0
            if retryCount < maxRecoveredAutoRetries {
                restoredJobs.append(QueuedJob(url: url))
                setInterruptedRetryCount(retryCount + 1, for: url)
            } else {
                deferredInterruptedJob = QueuedJob(url: url)
                shouldAutoStartRestoredQueue = false
            }
        }

        for persistedURL in persistedQueueURLs {
            guard let url = normalizedURL(from: persistedURL) else { continue }
            if seenURLs.insert(url.absoluteString).inserted {
                restoredJobs.append(QueuedJob(url: url))
            }
        }

        guard !restoredJobs.isEmpty || deferredInterruptedJob != nil else { return }

        isRestoringQueueState = true
        queuedJobs = restoredJobs
        currentJob = nil
        isRestoringQueueState = false
        persistQueueState()

        if persistedCurrentURL != nil {
            appendLog("Recovered an interrupted scrape and restored \(restoredJobs.count) queued site(s).")
        } else {
            appendLog("Restored \(restoredJobs.count) queued site(s) from the previous session.")
        }

        if let deferredInterruptedJob {
            queuedJobs.append(deferredInterruptedJob)
            appendLog("Recovered \(deferredInterruptedJob.displayText), but it was interrupted multiple times. Retry it manually after the rest of the queue.")
        }

        if shouldAutoStartRestoredQueue {
            startNextJobIfNeeded()
        } else if !restoredJobs.isEmpty {
            appendLog("Automatic restart was skipped to avoid repeating the same stuck site immediately.")
            startNextJobIfNeeded()
        } else if !queuedJobs.isEmpty {
            appendLog("Automatic restart was skipped to avoid repeating the same stuck site immediately.")
        }
    }

    private func interruptedRetryCounts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: interruptedRetryCountsKey) as? [String: Int] ?? [:]
    }

    private func setInterruptedRetryCount(_ count: Int, for url: URL) {
        var counts = interruptedRetryCounts()
        counts[url.absoluteString] = count
        UserDefaults.standard.set(counts, forKey: interruptedRetryCountsKey)
    }

    private func clearInterruptedRetryCount(for url: URL?) {
        guard let url else { return }
        var counts = interruptedRetryCounts()
        counts.removeValue(forKey: url.absoluteString)
        UserDefaults.standard.set(counts, forKey: interruptedRetryCountsKey)
    }

    private func runScrapeWithTimeout<T: Sendable>(
        for job: QueuedJob,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = Int(siteTimeout.components.seconds)
        let timeout = siteTimeout
        let race = TimeoutRace<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.setContinuation(continuation)

                let scrapeTask = Task {
                    do {
                        race.resolve(.success(try await operation()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        race.resolve(.failure(ScrapeTimeoutError(seconds: timeoutSeconds)))
                    } catch is CancellationError {
                        // The scrape completed or the user stopped it before the timeout.
                    } catch {
                        race.resolve(.failure(error))
                    }
                }

                race.setTasks([scrapeTask, timeoutTask])
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }

    private func installCLIWrapperIfNeeded() {
        guard !attemptedCLISetup else { return }
        attemptedCLISetup = true

        guard let appBundlePath = currentAppBundlePath() else { return }
        let defaults = UserDefaults.standard
        let wrapperScript = cliWrapperScript(appBundlePath: appBundlePath)
        let previousBundlePath = defaults.string(forKey: installedBundlePathKey)

        guard previousBundlePath != appBundlePath || needsCLIWrapperInstall(expectedScript: wrapperScript) else {
            return
        }

        if installCLIWrapper(at: cliInstallPath, contents: wrapperScript) {
            defaults.set(appBundlePath, forKey: installedBundlePathKey)
            defaults.removeObject(forKey: failedPromptBundlePathKey)
            return
        }

        guard defaults.string(forKey: failedPromptBundlePathKey) != appBundlePath else {
            return
        }

        do {
            try installCLIWrapperWithPrivileges(at: cliInstallPath, contents: wrapperScript)
            defaults.set(appBundlePath, forKey: installedBundlePathKey)
            defaults.removeObject(forKey: failedPromptBundlePathKey)
        } catch {
            defaults.set(appBundlePath, forKey: failedPromptBundlePathKey)
            appendLog("Terminal command could not be installed automatically.")
        }
    }

    private func currentAppBundlePath() -> String? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.path
    }

    private func needsCLIWrapperInstall(expectedScript: String) -> Bool {
        guard let existingContents = try? String(contentsOfFile: cliInstallPath, encoding: .utf8) else {
            return true
        }
        return existingContents != expectedScript
    }

    private func cliWrapperScript(appBundlePath: String) -> String {
        """
        #!/bin/bash
        APP_BUNDLE=\(shellQuoted(appBundlePath))
        CLI_BINARY="$APP_BUNDLE/Contents/MacOS/\(bundledCLIName)"
        SELF_PATH="$0"

        if [ ! -d "$APP_BUNDLE" ] || [ ! -x "$CLI_BINARY" ]; then
            rm -f "$SELF_PATH"
            echo "\(cliCommandName) could not find Folio Scraper. The terminal command has been removed." >&2
            exit 1
        fi

        exec "$CLI_BINARY" "$@"
        """
    }

    private func installCLIWrapper(at installPath: String, contents: String) -> Bool {
        let installDirectory = URL(fileURLWithPath: installPath).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: installDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: installPath) {
                try FileManager.default.removeItem(atPath: installPath)
            }
            try contents.write(toFile: installPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installPath)
            return true
        } catch {
            return false
        }
    }

    private func installCLIWrapperWithPrivileges(at installPath: String, contents: String) throws {
        let installDirectory = URL(fileURLWithPath: installPath).deletingLastPathComponent().path
        let encodedContents = Data(contents.utf8).base64EncodedString()
        let command = """
        mkdir -p \(shellQuoted(installDirectory)) && rm -f \(shellQuoted(installPath)) && printf %s \(shellQuoted(encodedContents)) | /usr/bin/base64 -D > \(shellQuoted(installPath)) && chmod 755 \(shellQuoted(installPath))
        """
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "FolioScraper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Administrator installation was cancelled or failed."]
            )
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private extension UserDefaults {
    func persistedBool(forKey key: String) -> Bool? {
        guard object(forKey: key) != nil else { return nil }
        return bool(forKey: key)
    }
}
