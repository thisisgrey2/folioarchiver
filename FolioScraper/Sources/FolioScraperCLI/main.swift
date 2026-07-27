import AppKit
import FolioScraperCore
import Foundation

struct FolioScraperCLI {
    static func run() async {
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(CLICommand.usage)
            exit(0)
        }

        do {
            let command = try CLICommand(arguments: CommandLine.arguments)
            await MainActor.run {
                _ = NSApplication.shared
            }
            let scraper = PortfolioScraperService()

            switch command.mode {
            case .scrape(let url):
                let result = try await scrape(
                    url: url,
                    maxImages: command.maxImages,
                    outputRoot: command.outputRoot,
                    saveDetails: command.saveDetails,
                    scraper: scraper
                )
                printSummary(result)
            case .batch(let urls):
                for url in urls {
                    let result = try await scrape(
                        url: url,
                        maxImages: command.maxImages,
                        outputRoot: command.outputRoot,
                        saveDetails: command.saveDetails,
                        scraper: scraper
                    )
                    printSummary(result)
                }
            }
        } catch let error as CLIError {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            fputs(CLICommand.usage, stderr)
            exit(1)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func scrape(
        url: URL,
        maxImages: Int,
        outputRoot: URL?,
        saveDetails: Bool,
        scraper: PortfolioScraperService
    ) async throws -> ScrapeResult {
        print("Scraping \(url.absoluteString)")
        return try await scraper.scrape(
            startURL: url,
            maxImages: maxImages,
            outputRoot: outputRoot,
            saveDetails: saveDetails
        ) { line in
            print(line)
        }
    }

    private static func printSummary(_ result: ScrapeResult) {
        print("Finished \(result.studio)")
        print("Platform: \(result.platform) | Saved: \(result.downloaded.count) | Too small: \(result.skippedSmall) | Too large: \(result.skippedLarge) | Failed: \(result.errors)")
        print("Output: \(result.outputDirectory.path)")
        print("")
    }
}

Task {
    await FolioScraperCLI.run()
    exit(0)
}
RunLoop.main.run()

private struct CLICommand {
    enum Mode {
        case scrape(URL)
        case batch([URL])
    }

    let mode: Mode
    let maxImages: Int
    let outputRoot: URL?
    let saveDetails: Bool

    static let usage = """
    Usage:
      folioscraper scrape <url> [--max-images <count>] [--output <folder>] [--save-details]
      folioscraper batch <file> [--max-images <count>] [--output <folder>] [--save-details]

    Batch files should contain one URL per line.
    --max-images must be between 1 and 10000.
    --save-details writes a details.md file with the studio name and URL.
    """

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage
        }

        let command = arguments[1]
        var maxImages = 1_000
        var outputRoot: URL?
        var saveDetails = false
        var positionals: [String] = []

        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--max-images":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      (1...10_000).contains(value) else {
                    throw CLIError.invalidOption("--max-images")
                }
                maxImages = value
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidOption("--output")
                }
                outputRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--save-details":
                saveDetails = true
            case "--help", "-h":
                throw CLIError.usage
            default:
                positionals.append(argument)
            }
            index += 1
        }

        switch command {
        case "scrape":
            guard positionals.count == 1, let url = Self.normalizeURL(positionals[0]) else {
                throw CLIError.invalidCommand
            }
            self.mode = .scrape(url)
        case "batch":
            guard positionals.count == 1 else {
                throw CLIError.invalidCommand
            }
            let urls = try Self.loadURLs(from: positionals[0])
            self.mode = .batch(urls)
        default:
            throw CLIError.invalidCommand
        }

        self.maxImages = maxImages
        self.outputRoot = outputRoot
        self.saveDetails = saveDetails
    }

    private static func loadURLs(from path: String) throws -> [URL] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let urls = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap(normalizeURL)

        guard !urls.isEmpty else {
            throw CLIError.emptyBatchFile
        }

        return urls
    }

    private static func normalizeURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
            return url
        }
        return URL(string: "https://\(string)")
    }
}

private enum CLIError: LocalizedError {
    case usage
    case invalidCommand
    case invalidOption(String)
    case emptyBatchFile

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Missing or invalid arguments."
        case .invalidCommand:
            return "Use `scrape <url>` or `batch <file>`."
        case .invalidOption(let option):
            return "Invalid value for \(option)."
        case .emptyBatchFile:
            return "The batch file did not contain any usable URLs."
        }
    }
}
