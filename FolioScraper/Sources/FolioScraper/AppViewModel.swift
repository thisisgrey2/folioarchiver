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

@MainActor
final class AppViewModel: ObservableObject {
    let maxImageOptions = [50, 200, 400]
    private let cliCommandName = "folioscraper"
    private let bundledCLIName = "folioscraper-cli"
    private let cliInstallPath = "/usr/local/bin/folioscraper"
    private let installedBundlePathKey = "installedCLIAppBundlePath"
    private let failedPromptBundlePathKey = "failedCLIInstallPromptBundlePath"
    private let queuedJobURLsKey = "queuedJobURLs"
    private let currentJobURLKey = "currentJobURL"

    @Published var inputURL = ""
    @Published var selectedMaxImages = 200
    @Published var saveDetails = true
    @Published var downloadSmallImages = false
    @Published var checkForDuplicates = true
    @Published var organizeImagesBySourcePage = true
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
    private var isRestoringQueueState = false

    init() {
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
                let result = try await self.scraper.scrape(
                    startURL: nextJob.url,
                    maxImages: self.selectedMaxImages,
                    outputRoot: nil,
                    saveDetails: self.saveDetails,
                    downloadSmallImages: self.downloadSmallImages,
                    checkForDuplicates: self.checkForDuplicates,
                    organizeImagesBySourcePage: self.organizeImagesBySourcePage
                ) { line in
                    await MainActor.run {
                        self.appendLog(line)
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
        queuedJobs.removeAll { $0.id == id }
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

    private func restoreQueueState() {
        let defaults = UserDefaults.standard
        let persistedQueueURLs = defaults.stringArray(forKey: queuedJobURLsKey) ?? []
        let persistedCurrentURL = defaults.string(forKey: currentJobURLKey)

        var restoredJobs: [QueuedJob] = []
        var seenURLs = Set<String>()

        if let persistedCurrentURL,
           let url = normalizedURL(from: persistedCurrentURL) {
            restoredJobs.append(QueuedJob(url: url))
            seenURLs.insert(url.absoluteString)
        }

        for persistedURL in persistedQueueURLs {
            guard let url = normalizedURL(from: persistedURL) else { continue }
            if seenURLs.insert(url.absoluteString).inserted {
                restoredJobs.append(QueuedJob(url: url))
            }
        }

        guard !restoredJobs.isEmpty else { return }

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

        startNextJobIfNeeded()
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
