import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ScrapeResult: Sendable {
    public let studio: String
    public let outputDirectory: URL
    public let foundCandidates: Int
    public let downloaded: [URL]
    public let skippedSmall: Int
    public let skippedLarge: Int
    public let errors: Int
    public let platform: String
}

private enum PortfolioScraperError: LocalizedError {
    case httpStatus(code: Int, url: URL?)
    case emptyAsset(url: URL?)
    case timedOut(step: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let url):
            if let url {
                return "HTTP \(code) for \(url.absoluteString)"
            }
            return "HTTP \(code)"
        case .emptyAsset(let url):
            if let url {
                return "Empty asset payload for \(url.absoluteString)"
            }
            return "Empty asset payload"
        case .timedOut(let step, let seconds):
            return "\(step) timed out after \(seconds) seconds"
        }
    }
}

private struct AssetCandidate {
    let url: URL
    let referer: URL?
}

private struct AssetResponse {
    let data: Data
    let mimeType: String?
}

private struct CargoProject {
    let url: URL?
    let thumbnailURL: URL?
}

private struct CargoCatalog {
    let projects: [CargoProject]
    let collectionCount: Int
    let failedCollections: Int
}

private struct ImageFingerprint {
    let structureHash: UInt64
    let colorSignature: [UInt8]
    let redHash: UInt64
    let greenHash: UInt64
    let blueHash: UInt64
    let width: Int
    let height: Int

    var pixelArea: Int {
        width * height
    }
}

private struct SavedImageRecord {
    var fileURL: URL
    var contentHash: String
    var fingerprint: ImageFingerprint
}

private struct DownloadedImagePayload {
    let data: Data
    let preferredName: String
    let width: Int
    let height: Int
    let contentHash: String
    let fingerprint: ImageFingerprint?
    let destinationDirectory: URL
}

private struct DownloadedVideoPayload {
    let data: Data
    let preferredName: String
    let contentHash: String
    let destinationDirectory: URL
}

private enum MediaKind {
    case image
    case video

    var folderName: String {
        switch self {
        case .image:
            return "Images"
        case .video:
            return "Videos"
        }
    }
}

public actor PortfolioScraperService {
    private let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private let maxVideoBytes = 50 * 1024 * 1024
    private let maxCrawlPages = 500
    private let maxCargoCollections = 100
    private let minPixelSize = 900
    private let maxFilenameLength = 120
    private let curlTimeout: Duration = .seconds(180)
    private let maximumTransientAttempts = 2
    private let transientRetryDelay: Duration = .seconds(2)
    private let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "avif"])
    private let videoExtensions = Set(["mp4", "mov", "webm", "m4v", "ogv"])
    private let stripQueryPrefixes = [
        "https://www.datocms-assets.com/",
        "https://images.datocms-assets.com/",
        "https://images.ctfassets.net/",
        "https://cdn.sanity.io/"
    ]
    private let nonPageExtensions = Set([
        "css", "js", "json", "xml", "txt", "map", "pdf",
        "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico",
        "mp4", "mov", "webm", "m4v", "ogv", "mp3", "wav", "zip"
    ])
    private let slugTemplates = [
        "/work/%@",
        "/works/%@",
        "/projects/%@",
        "/case-studies/%@",
        "/case-study/%@",
        "/portfolio/%@"
    ]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": browserUserAgent
        ]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func scrape(
        startURL: URL,
        maxImages: Int,
        outputRoot: URL?,
        saveDetails: Bool,
        downloadSmallImages: Bool = false,
        downloadVideos: Bool = true,
        organizeImagesBySourcePage: Bool = true,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> ScrapeResult {
        try Task.checkCancellation()
        let normalizedStartURL = normalizedStartURL(from: startURL)
        let studio = studioName(from: normalizedStartURL)
        let outputBase = outputRoot ?? desktopDirectory()
        let outputDirectory = outputBase.appendingPathComponent(studio, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let mediaDirectory = outputDirectory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        if saveDetails {
            try writeDetailsFile(studio: studio, url: normalizedStartURL, outputDirectory: outputDirectory)
        }

        var crawled = Set<URL>()
        var toCrawl = [normalizedStartURL]
        var allCandidates: [URL: URL] = [:]
        var crawledStylesheets = Set<URL>()
        var isCargo = false
        var cargoCatalogWasRead = false
        var cargoProjectPagesWereQueued = false
        var usedPageData = false

        while let url = toCrawl.first, crawled.count < maxCrawlPages {
            try Task.checkCancellation()
            toCrawl.removeFirst()
            guard crawled.insert(url).inserted else { continue }
            var rawPageWasFetched = false

            // Start with page data, then use the browser only when the page suggests
            // lazy or script-driven media that source parsing cannot reliably expose.
            if let (html, finalURL) = try? await fetchString(from: url) {
                rawPageWasFetched = true
                let isCargoPage = html.contains("\"version\":\"Cargo3\"") || html.contains("freight.cargo.site") || html.contains("cargo.site")
                var rawCandidates = extractCandidates(from: html, baseURL: finalURL)
                rawCandidates.formUnion(
                    await stylesheetCandidates(
                        from: html,
                        baseURL: finalURL,
                        crawledStylesheets: &crawledStylesheets
                    )
                )
                mergeCandidates(
                    rawCandidates,
                    sourcePage: finalURL,
                    into: &allCandidates
                )

                // Follow the site's own project links, but avoid speculative URL probes
                // when the page already provides a working media list.
                let internalLinks = extractInternalLinks(from: html, baseURL: finalURL)
                enqueueDiscoveredLinks(internalLinks, crawled: crawled, pending: &toCrawl)

                if isCargoPage {
                    if url == normalizedStartURL {
                        isCargo = true
                        await progress("Cargo detected. Reading public project catalogue.")

                        if !cargoCatalogWasRead {
                            cargoCatalogWasRead = true
                            let catalog = await cargoCatalog(from: html, baseURL: finalURL)
                            let projectURLs = catalog.projects.compactMap(\.url)
                            let thumbnailURLs = Set(catalog.projects.compactMap(\.thumbnailURL))

                            mergeCandidates(
                                thumbnailURLs,
                                sourcePage: finalURL,
                                into: &allCandidates
                            )
                            enqueueDiscoveredLinks(projectURLs, crawled: crawled, pending: &toCrawl)

                            if !projectURLs.isEmpty {
                                cargoProjectPagesWereQueued = true
                                let failureSuffix = catalog.failedCollections == 0
                                    ? ""
                                    : " (\(catalog.failedCollections) collection(s) unavailable)"
                                await progress(
                                    "Cargo catalogue found \(projectURLs.count) public project page(s) across \(catalog.collectionCount) collection(s)\(failureSuffix)."
                                )
                            } else {
                                let staticProjectLinks = extractCargoProjectLinks(from: html, baseURL: finalURL)
                                enqueueDiscoveredLinks(staticProjectLinks, crawled: crawled, pending: &toCrawl)
                                cargoProjectPagesWereQueued = !staticProjectLinks.isEmpty
                                await progress("Cargo catalogue exposed no project pages. Using page-data fallback.")
                            }
                        }
                    }

                    // Cargo project pages expose their own media in page data. Avoid the
                    // browser unless both its catalogue and raw page data were unavailable.
                    if url != normalizedStartURL || cargoProjectPagesWereQueued {
                        continue
                    }
                }

                if url == normalizedStartURL {
                    let slugLinks = await extractSlugLinks(from: html, baseURL: finalURL)
                    enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                }

                if !rawCandidates.isEmpty {
                    usedPageData = true
                    if !needsRenderedDiscovery(for: html, rawCandidateCount: rawCandidates.count) {
                        await progress("Found media in page data. Browser rendering is not needed.")
                        continue
                    }
                    await progress("Found page media. Checking dynamic content as well.")
                }
            }

            await progress("Rendering \(url.absoluteString)")

            do {
                let snapshot = try await RenderedPageCrawler.capture(url: url)
                if url == normalizedStartURL {
                    isCargo = snapshot.html.contains("freight.cargo.site") || snapshot.html.contains("cargo.site")
                    if isCargo {
                        await progress("Cargo detected. Using rendered web crawl mode.")
                    }
                }
                mergeCandidates(
                    extractCandidates(from: snapshot.html, baseURL: snapshot.finalURL),
                    sourcePage: snapshot.finalURL,
                    into: &allCandidates
                )
                mergeCandidates(
                    normalizedAssetCandidates(from: snapshot.assetCandidates, baseURL: snapshot.finalURL),
                    sourcePage: snapshot.finalURL,
                    into: &allCandidates
                )

                let htmlLinks = extractInternalLinks(from: snapshot.html, baseURL: snapshot.finalURL)
                let domLinks = normalizedInternalLinks(from: snapshot.internalLinkCandidates, siteURL: snapshot.finalURL)
                enqueueDiscoveredLinks(Array(Set(htmlLinks + domLinks)), crawled: crawled, pending: &toCrawl)

                if url == normalizedStartURL {
                    let slugLinks = await extractSlugLinks(from: snapshot.html, baseURL: snapshot.finalURL)
                    enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                }

                if !rawPageWasFetched {
                    do {
                    let (html, finalURL) = try await fetchString(from: url)
                        var candidates = extractCandidates(from: html, baseURL: finalURL)
                        candidates.formUnion(
                            await stylesheetCandidates(
                                from: html,
                                baseURL: finalURL,
                                crawledStylesheets: &crawledStylesheets
                            )
                        )
                        mergeCandidates(candidates, sourcePage: finalURL, into: &allCandidates)

                        let internalLinks = extractInternalLinks(from: html, baseURL: finalURL)
                        enqueueDiscoveredLinks(internalLinks, crawled: crawled, pending: &toCrawl)

                        if url == normalizedStartURL {
                            let slugLinks = await extractSlugLinks(from: html, baseURL: finalURL)
                            enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                        }
                    } catch {
                        // Keep the rendered crawl results even if the raw HTML fetch is blocked.
                    }
                }
            } catch {
                await progress("Rendered crawl failed for \(url.absoluteString): \(error.localizedDescription)")

                if !rawPageWasFetched {
                    do {
                    let (html, finalURL) = try await fetchString(from: url)
                        var candidates = extractCandidates(from: html, baseURL: finalURL)
                        candidates.formUnion(
                            await stylesheetCandidates(
                                from: html,
                                baseURL: finalURL,
                                crawledStylesheets: &crawledStylesheets
                            )
                        )
                        mergeCandidates(candidates, sourcePage: finalURL, into: &allCandidates)

                        let internalLinks = extractInternalLinks(from: html, baseURL: finalURL)
                        enqueueDiscoveredLinks(internalLinks, crawled: crawled, pending: &toCrawl)

                        if url == normalizedStartURL {
                            let slugLinks = await extractSlugLinks(from: html, baseURL: finalURL)
                            enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                        }
                    } catch {
                        await progress("Failed to crawl \(url.absoluteString): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !toCrawl.isEmpty {
            await progress("Reached the \(maxCrawlPages)-page crawl limit with \(toCrawl.count) page(s) still queued.")
        }

        let upgradedCandidates = upgradeWordPressCandidates(in: allCandidates)
        let deduped = selectLargestAssetVariants(from: Set(upgradedCandidates.keys))
            .sorted { lhs, rhs in
                let lhsIsImage = imageExtensions.contains(lhs.pathExtension.lowercased())
                let rhsIsImage = imageExtensions.contains(rhs.pathExtension.lowercased())
                if lhsIsImage != rhsIsImage {
                    return lhsIsImage
                }
                return lhs.absoluteString < rhs.absoluteString
            }
            .map {
            AssetCandidate(url: $0, referer: upgradedCandidates[$0])
        }
        await progress("Found \(deduped.count) candidate files")

        let downloadResult = try await downloadCandidates(
            deduped,
            maxImages: maxImages,
            outputDirectory: mediaDirectory,
            downloadSmallImages: downloadSmallImages,
            downloadVideos: downloadVideos,
            organizeImagesBySourcePage: organizeImagesBySourcePage,
            progress: progress
        )

        return ScrapeResult(
            studio: studio,
            outputDirectory: outputDirectory,
            foundCandidates: deduped.count,
            downloaded: downloadResult.downloaded,
            skippedSmall: downloadResult.skippedSmall,
            skippedLarge: downloadResult.skippedLarge,
            errors: downloadResult.errors,
            platform: isCargo ? "Cargo (Public project catalogue)" : (usedPageData ? "Page data crawl" : "Rendered web crawl")
        )
    }

    private func normalizedStartURL(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == nil {
            components?.scheme = "https"
        }
        if components?.host == nil, let path = components?.path, !path.isEmpty {
            components?.host = path
            components?.path = ""
        }
        components?.fragment = nil
        return components?.url ?? url
    }

    private func desktopDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func writeDetailsFile(studio: String, url: URL, outputDirectory: URL) throws {
        let detailsURL = outputDirectory.appendingPathComponent("details.md")
        let contents = """
        # \(studio)

        \(url.absoluteString)
        """
        try contents.write(to: detailsURL, atomically: true, encoding: .utf8)
    }

    private func studioName(from url: URL) -> String {
        let host = (url.host ?? "portfolio").lowercased().replacingOccurrences(of: "www.", with: "")
        let studio = host.split(separator: ".").first.map(String.init) ?? "portfolio"
        let displayStudio = studio.prefix(1).uppercased() + studio.dropFirst()
        let pathComponents = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map { component in
                component.removingPercentEncoding ?? component
            }

        let folderName: String
        if pathComponents.isEmpty {
            folderName = displayStudio
        } else {
            folderName = ([displayStudio] + pathComponents).joined(separator: " ")
        }

        let sanitized = sanitizeBaseName(folderName)
        return sanitized.isEmpty ? "Portfolio" : sanitized
    }

    private func fetchString(from url: URL, referer: URL? = nil) async throws -> (String, URL) {
        let request = makeRequest(url: url, referer: referer)
        let (data, response) = try await dataWithTransientRetry(for: request)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }

        // Some portfolio hosts send a 5xx status for a complete page. Keep a substantial
        // HTML document available to the media parser instead of discarding usable content.
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode),
           !(html.count >= 4_096 && html.range(of: "<html", options: .caseInsensitive) != nil) {
            _ = try validateSuccessfulHTTP(response, fallbackURL: url)
        }
        return (html, response.url ?? url)
    }

    private func makeRequest(url: URL, method: String = "GET", referer: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if url.host?.lowercased() == "freight.cargo.site",
           imageExtensions.contains(url.pathExtension.lowercased()) {
            // Cargo's CDN rejects generic HTTP clients for image transforms. These match
            // the headers sent by an ordinary browser image request.
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-GB,en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("image", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("i", forHTTPHeaderField: "Priority")
        }
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if url.host == referer.host,
               let scheme = referer.scheme,
               let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        return request
    }

    private func dataWithTransientRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 1...maximumTransientAttempts {
            try Task.checkCancellation()

            do {
                let result = try await session.data(for: request)
                if isTransientHTTPResponse(result.1), attempt < maximumTransientAttempts {
                    try await Task.sleep(for: transientRetryDelay)
                    continue
                }
                return result
            } catch {
                guard isTransientNetworkError(error), attempt < maximumTransientAttempts else {
                    throw error
                }
                try await Task.sleep(for: transientRetryDelay)
            }
        }

        throw URLError(.unknown)
    }

    private func isTransientHTTPResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        let status = httpResponse.statusCode
        return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func extractCandidates(from html: String, baseURL: URL) -> Set<URL> {
        var found = Set<URL>()

        insertAttributeCandidates(
            named: [
                "src", "data-src", "data-lazy-src", "data-original",
                "data-image", "data-image-src", "data-background", "data-background-image",
                "data-bg", "data-video-src", "poster"
            ],
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertSrcsetCandidates(
            named: ["srcset", "data-srcset", "imagesrcset", "data-imagesrcset"],
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertCSSURLCandidates(from: html, baseURL: baseURL, into: &found)
        insertJSONMediaCandidates(from: html, baseURL: baseURL, into: &found)
        insertRegexMatches(
            pattern: #"https://static\.wixstatic\.com/media/[^\s"'<>]+"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertRegexMatches(
            pattern: #"https://(?:www\.)?datocms-assets\.com/[^\s"'<>]+\.(?:jpg|jpeg|png|webp|avif|gif)"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertRegexMatches(
            pattern: #"https://[^\s"'<>]+\.(?:mp4|mov|webm|m4v)"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertCargoMediaCandidates(from: html, into: &found)
        insertSanityImageCandidates(from: html, into: &found)

        return found
    }

    private func needsRenderedDiscovery(for html: String, rawCandidateCount: Int) -> Bool {
        if rawCandidateCount < 4 {
            return true
        }

        let lowered = html.lowercased()
        let dynamicMarkers = [
            "intersectionobserver", "infinite-scroll", "data-infinite", "__next_data__",
            "self.__next_f", "__nuxt__", "__remixcontext", "astro-island", "sveltekit"
        ]
        return dynamicMarkers.contains { lowered.contains($0) }
    }

    private func stylesheetCandidates(
        from html: String,
        baseURL: URL,
        crawledStylesheets: inout Set<URL>
    ) async -> Set<URL> {
        var pending = stylesheetURLs(from: html, baseURL: baseURL)
        var found = Set<URL>()

        while let stylesheetURL = pending.popLast() {
            guard crawledStylesheets.insert(stylesheetURL).inserted,
                  let (stylesheet, finalURL) = try? await fetchString(from: stylesheetURL, referer: baseURL) else {
                continue
            }

            insertCSSURLCandidates(from: stylesheet, baseURL: finalURL, into: &found)
            pending.append(contentsOf: importedStylesheetURLs(from: stylesheet, baseURL: finalURL))
        }

        return found
    }

    private func stylesheetURLs(from html: String, baseURL: URL) -> [URL] {
        let pattern = #"<link\b(?=[^>]*\brel\s*=\s*["'][^"']*\bstylesheet\b[^"']*["'])(?=[^>]*\bhref\s*=\s*["']([^"']+)["'])[^>]*>"#
        return regexMatches(pattern: pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .compactMap { normalize(candidate: $0, baseURL: baseURL) }
    }

    private func importedStylesheetURLs(from stylesheet: String, baseURL: URL) -> [URL] {
        let pattern = #"@import\s+(?:url\(\s*)?["']?([^"'\s\)]+)"#
        return regexMatches(pattern: pattern, in: stylesheet)
            .compactMap { normalize(candidate: $0, baseURL: baseURL) }
    }

    private func extractInternalLinks(from html: String, baseURL: URL) -> [URL] {
        return attributeValues(named: "href", in: html)
            .compactMap { crawlableInternalURL(from: $0, baseURL: baseURL, siteURL: baseURL) }
    }

    private func normalizedAssetCandidates(from rawCandidates: [String], baseURL: URL) -> Set<URL> {
        Set(rawCandidates.compactMap { normalize(candidate: $0, baseURL: baseURL) })
    }

    private func mergeCandidates(_ urls: Set<URL>, sourcePage: URL, into candidates: inout [URL: URL]) {
        for url in urls {
            if let existing = candidates[url] {
                if shouldPreferReferer(sourcePage, over: existing) {
                    candidates[url] = sourcePage
                }
            } else {
                candidates[url] = sourcePage
            }
        }
    }

    private func normalizedInternalLinks(from rawLinks: [String], siteURL: URL) -> [URL] {
        return rawLinks.compactMap { rawValue in
            crawlableInternalURL(from: rawValue, baseURL: siteURL, siteURL: siteURL)
        }
    }

    private func insertAttributeCandidates(
        named attributes: [String],
        from html: String,
        baseURL: URL,
        into found: inout Set<URL>
    ) {
        for attribute in attributes {
            for rawValue in attributeValues(named: attribute, in: html) {
                insertCandidate(rawValue, baseURL: baseURL, into: &found)
            }
        }
    }

    private func insertSrcsetCandidates(
        named attributes: [String],
        from html: String,
        baseURL: URL,
        into found: inout Set<URL>
    ) {
        for attribute in attributes {
            for rawValue in attributeValues(named: attribute, in: html) {
                for part in rawValue.split(separator: ",") {
                    let candidate = part.split(separator: " ").first.map(String.init) ?? ""
                    insertCandidate(candidate, baseURL: baseURL, into: &found)
                }
            }
        }
    }

    private func insertRegexMatches(
        pattern: String,
        from html: String,
        baseURL: URL,
        into found: inout Set<URL>
    ) {
        for rawValue in regexMatches(pattern: pattern, in: html) {
            insertCandidate(rawValue, baseURL: baseURL, into: &found)
        }
    }

    private func insertCSSURLCandidates(from text: String, baseURL: URL, into found: inout Set<URL>) {
        let fontExtensions = Set(["eot", "otf", "ttf", "woff", "woff2"])
        for rawValue in regexMatches(pattern: #"url\(\s*["']?([^"'\)\s]+)"#, in: text) {
            guard let url = normalize(candidate: rawValue, baseURL: baseURL),
                  !fontExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            found.insert(url)
        }
    }

    private func insertJSONMediaCandidates(from html: String, baseURL: URL, into found: inout Set<URL>) {
        insertRegexMatches(
            pattern: #"["'](?:src|image|imageurl|image_url|mediaurl|media_url|video|videourl|video_url|poster)["']\s*:\s*["']([^"']+)["']"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertRegexMatches(
            pattern: #"((?:https?:)?//[^\s"'<>\\]+\.(?:jpg|jpeg|png|webp|gif|avif|mp4|mov|webm|m4v|ogv)(?:\?[^\s"'<>\\]*)?)"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
    }

    private func insertSanityImageCandidates(from html: String, into found: inout Set<URL>) {
        guard let sanityConfig = sanityProjectConfiguration(in: html) else { return }

        let imageRefs = Set(
            regexMatches(
                pattern: #"(image-[a-f0-9]+-\d+x\d+-(?:jpg|jpeg|png|webp|gif|avif))"#,
                in: html,
                options: [.caseInsensitive]
            )
        )

        for ref in imageRefs {
            guard let url = sanityImageURL(for: ref, projectID: sanityConfig.projectID, dataset: sanityConfig.dataset) else {
                continue
            }
            found.insert(url)
        }
    }

    private func insertCandidate(_ rawValue: String, baseURL: URL, into found: inout Set<URL>) {
        if let normalized = normalize(candidate: rawValue, baseURL: baseURL) {
            found.insert(normalized)
        }
    }

    private func sanityProjectConfiguration(in html: String) -> (projectID: String, dataset: String)? {
        guard let projectID = firstMatch(
            pattern: #"(?:\"projectId\"|projectId)\s*:\s*\"([a-z0-9]+)\""#,
            in: html
        ),
        let dataset = firstMatch(
            pattern: #"(?:\"dataset\"|dataset)\s*:\s*\"([a-z0-9_-]+)\""#,
            in: html
        ) else {
            return nil
        }

        return (projectID, dataset)
    }

    private func sanityImageURL(for ref: String, projectID: String, dataset: String) -> URL? {
        let pattern = #"^image-([a-f0-9]+)-(\d+x\d+)-([a-z0-9]+)$"#
        guard let captures = firstCaptureGroups(pattern: pattern, in: ref),
              captures.count == 3 else {
            return nil
        }

        return URL(string: "https://cdn.sanity.io/images/\(projectID)/\(dataset)/\(captures[0])-\(captures[1]).\(captures[2])")
    }

    private func crawlableInternalURL(from rawValue: String, baseURL: URL, siteURL: URL) -> URL? {
        guard let normalized = normalize(candidate: rawValue, baseURL: baseURL) else { return nil }
        guard isSameSite(normalized, as: siteURL) else { return nil }
        guard shouldCrawlPage(url: normalized) else { return nil }
        let crawlURL = canonicalCrawlURL(from: normalized)
        guard crawlURL != canonicalCrawlURL(from: siteURL) else { return nil }
        return crawlURL
    }

    private func isSameSite(_ candidate: URL, as siteURL: URL) -> Bool {
        guard let candidateHost = candidate.host?.lowercased(),
              let siteHost = siteURL.host?.lowercased() else {
            return false
        }

        return canonicalHost(candidateHost) == canonicalHost(siteHost)
    }

    private func canonicalHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func canonicalCrawlURL(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let filteredQueryItems = components?.queryItems?
            .filter { !isTrackingQueryItem($0.name) }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return (lhs.value ?? "") < (rhs.value ?? "")
                }
                return lhs.name < rhs.name
            }
        components?.queryItems = filteredQueryItems
        return components?.url ?? url
    }

    private func isTrackingQueryItem(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || ["fbclid", "gclid", "dclid", "mc_cid", "mc_eid"].contains(lowered)
    }

    private func enqueueDiscoveredLinks(_ links: [URL], crawled: Set<URL>, pending: inout [URL]) {
        // Portfolio pages often list navigation links before the actual work. Put likely
        // project URLs first so the crawl reaches their media before secondary pages.
        for link in links.sorted(by: { crawlPriority(for: $0) > crawlPriority(for: $1) }) {
            if crawled.contains(link) || pending.contains(link) {
                continue
            }
            pending.append(link)
        }
    }

    private func crawlPriority(for url: URL) -> Int {
        let path = url.path.lowercased()
        if ["project", "work", "case", "portfolio"].contains(where: path.contains) {
            return 2
        }
        if ["about", "contact", "privacy", "legal", "terms"].contains(where: path.contains) {
            return 0
        }
        return 1
    }

    private func extractSlugLinks(from html: String, baseURL: URL) async -> [URL] {
        let cargoLinks = extractCargoProjectLinks(from: html, baseURL: baseURL)
        if !cargoLinks.isEmpty {
            return cargoLinks
        }

        guard html.contains("self.__next_f") else { return [] }

        let navSlugs: Set<String> = [
            "about", "contact", "insights", "news", "blog", "privacy", "privacy-policy",
            "imprint", "legal", "careers", "jobs", "services", "service", "team",
            "product-design", "brands", "content", "code-of-conduct"
        ]

        let slugs = regexMatches(pattern: #""slug"\s*:\s*"([a-z0-9][a-z0-9\-]+)""#, in: html)
            .filter { !navSlugs.contains($0) && $0.count > 2 }

        guard !slugs.isEmpty else { return [] }

        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathPrefix = basePath.isEmpty ? "" : "/\(basePath)"
        var confirmed: [URL] = []

        for slug in Array(Set(slugs)).prefix(24) {
            for template in slugTemplates {
                let path = pathPrefix + String(format: template, slug)
                guard let candidate = URL(string: "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(path)") else {
                    continue
                }

                do {
                    let request = makeRequest(url: candidate, method: "HEAD")
                    let (_, response) = try await dataWithTransientRetry(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        confirmed.append(candidate)
                        break
                    }
                } catch {
                    continue
                }
            }
        }

        return confirmed
    }

    private func extractCargoProjectLinks(from html: String, baseURL: URL) -> [URL] {
        guard html.contains("cargo.site") || html.contains("\"version\":\"Cargo2\"") else {
            return []
        }

        var rawPaths = Set(
            regexMatches(
                pattern: #""project_url"\s*:\s*"([^"]+)""#,
                in: html,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        )
        rawPaths.formUnion(
            regexMatches(
                pattern: #""purl"\s*:\s*"([^"]+)""#,
                in: html,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        )
        rawPaths.formUnion(
            regexMatches(
                pattern: #"<media-item\b[^>]*\bhref="([^"]+)""#,
                in: html,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        )

        return rawPaths.compactMap { rawPath in
            let decodedPath = decodeHTMLEntities(in: rawPath.replacingOccurrences(of: #"\/"#, with: "/", options: .regularExpression))
            guard decodedPath != "0", !decodedPath.isEmpty else {
                return nil
            }
            return crawlableInternalURL(from: decodedPath, baseURL: baseURL, siteURL: baseURL)
        }
    }

    private func cargoCatalog(from html: String, baseURL: URL) async -> CargoCatalog {
        guard let state = cargoPreloadedState(from: html),
              let stateDictionary = state as? [String: Any],
              let site = stateDictionary["site"] as? [String: Any],
              let siteID = cargoSiteID(from: site) else {
            return CargoCatalog(projects: [], collectionCount: 0, failedCollections: 0)
        }

        let collectionIDs = cargoCollectionIDs(from: stateDictionary)
        guard !collectionIDs.isEmpty else {
            return CargoCatalog(projects: [], collectionCount: 0, failedCollections: 0)
        }

        var projectsByURL: [URL: CargoProject] = [:]
        var thumbnailOnlyProjects: [CargoProject] = []
        var failedCollections = 0

        for collectionID in collectionIDs.prefix(maxCargoCollections) {
            try? Task.checkCancellation()

            guard let endpoint = cargoThumbnailEndpoint(siteID: siteID, collectionID: collectionID) else {
                failedCollections += 1
                continue
            }

            do {
                let request = makeRequest(url: endpoint, referer: baseURL)
                let (data, response) = try await dataWithTransientRetry(for: request)
                _ = try validateSuccessfulHTTP(response, fallbackURL: endpoint)
                guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    failedCollections += 1
                    continue
                }

                for record in records where record["display"] as? Bool != false {
                    let project = CargoProject(
                        url: cargoProjectURL(from: record, baseURL: baseURL),
                        thumbnailURL: cargoThumbnailURL(from: record)
                    )

                    if let url = project.url {
                        projectsByURL[url] = project
                    } else if project.thumbnailURL != nil {
                        thumbnailOnlyProjects.append(project)
                    }
                }
            } catch {
                failedCollections += 1
            }
        }

        return CargoCatalog(
            projects: Array(projectsByURL.values) + thumbnailOnlyProjects,
            collectionCount: collectionIDs.count,
            failedCollections: failedCollections
        )
    }

    private func cargoSiteID(from site: [String: Any]) -> String? {
        if let id = site["id"] as? String, !id.isEmpty {
            return id
        }
        if let id = site["id"] as? NSNumber {
            return id.stringValue
        }
        return nil
    }

    private func cargoCollectionIDs(from state: [String: Any]) -> [String] {
        guard let sets = (state["sets"] as? [String: Any])?["byId"] as? [String: Any] else {
            return []
        }

        return sets.compactMap { id, value in
            guard let set = value as? [String: Any],
                  let pageCount = set["page_count"] as? NSNumber,
                  pageCount.intValue > 0 else {
                return nil
            }
            return id
        }
        .sorted()
    }

    private func cargoThumbnailEndpoint(siteID: String, collectionID: String) -> URL? {
        var components = URLComponents(string: "https://api.cargo.site/v1/pages/\(siteID)/thumbs/set/\(collectionID)")
        components?.queryItems = [URLQueryItem(name: "limit", value: "999")]
        return components?.url
    }

    private func cargoProjectURL(from record: [String: Any], baseURL: URL) -> URL? {
        let rawPath = (record["project_url"] as? String) ?? (record["purl"] as? String)
        guard let rawPath,
              !rawPath.isEmpty,
              !rawPath.hasPrefix("#") else {
            return nil
        }
        return crawlableInternalURL(from: rawPath, baseURL: baseURL, siteURL: baseURL)
    }

    private func cargoThumbnailURL(from record: [String: Any]) -> URL? {
        guard let thumbnail = record["thumbnail"] as? [String: Any] else {
            return nil
        }
        return cargoMediaURL(for: thumbnail)
    }

    private func insertCargoMediaCandidates(from html: String, into found: inout Set<URL>) {
        guard html.contains("media-item") || html.contains("\"version\":\"Cargo3\"") else {
            return
        }

        guard let state = cargoPreloadedState(from: html) else {
            return
        }

        for media in cargoMediaRecords(in: state) {
            guard let url = cargoMediaURL(for: media) else {
                continue
            }
            found.insert(url)
        }
    }

    private func cargoPreloadedState(from html: String) -> Any? {
        let marker = "window.__PRELOADED_STATE__="
        guard let markerRange = html.range(of: marker) else {
            return nil
        }

        let stateStart = markerRange.upperBound
        guard let scriptEnd = html[stateStart...].range(of: "</script>")?.lowerBound else {
            return nil
        }

        let json = String(html[stateStart..<scriptEnd])
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private func cargoMediaRecords(in object: Any) -> [[String: Any]] {
        var records: [[String: Any]] = []

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if isCargoMediaRecord(dictionary) {
                    records.append(dictionary)
                }
                for child in dictionary.values {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }

        walk(object)
        return records
    }

    private func isCargoMediaRecord(_ dictionary: [String: Any]) -> Bool {
        guard dictionary["hash"] as? String != nil,
              dictionary["name"] as? String != nil,
              let fileType = (dictionary["file_type"] as? String)?.lowercased() else {
            return false
        }

        return imageExtensions.contains(fileType) || videoExtensions.contains(fileType)
    }

    private func cargoMediaURL(for media: [String: Any]) -> URL? {
        guard let hash = media["hash"] as? String,
              let name = media["name"] as? String,
              !hash.isEmpty,
              !name.isEmpty else {
            return nil
        }

        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? name
        return URL(string: "https://freight.cargo.site/w/3000/q/90/i/\(hash)/\(encodedName)")
    }

    private func normalize(candidate rawValue: String, baseURL: URL) -> URL? {
        guard !rawValue.isEmpty else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlDecoded = decodeHTMLEntities(in: trimmed)
        let jsonDecoded = htmlDecoded
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
        let lowered = jsonDecoded.lowercased()
        guard !lowered.hasPrefix("data:"),
              !lowered.hasPrefix("blob:"),
              !lowered.hasPrefix("mailto:"),
              !lowered.hasPrefix("tel:"),
              !lowered.hasPrefix("javascript:") else {
            return nil
        }

        let extracted = extractNextImageURL(from: jsonDecoded)
        let resolved = URL(string: extracted, relativeTo: baseURL)?.absoluteURL
        guard var finalURL = resolved else { return nil }

        finalURL = upgradeWixURL(finalURL)
        finalURL = stripQueryIfNeeded(from: finalURL)
        return finalURL
    }

    private func extractNextImageURL(from string: String) -> String {
        guard string.contains("/_next/image"), let components = URLComponents(string: string) else {
            return string
        }

        if let urlItem = components.queryItems?.first(where: { $0.name == "url" })?.value {
            return urlItem.removingPercentEncoding ?? urlItem
        }

        return string
    }

    private func stripQueryIfNeeded(from url: URL) -> URL {
        let absolute = url.absoluteString
        guard stripQueryPrefixes.contains(where: absolute.hasPrefix) else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url ?? url
    }

    private func decodeHTMLEntities(in string: String) -> String {
        guard string.contains("&") else { return string }

        let wrapped = "<span>\(string)</span>"
        guard let data = wrapped.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return string
        }

        return attributed.string
    }

    private func upgradeWixURL(_ url: URL) -> URL {
        let absolute = url.absoluteString
        let patterns = [
            #"^(https://static\.wixstatic\.com/media/[^/]+~mv2\.[a-zA-Z]+)(?:/.*)?$"#,
            #"^(https://static\.wixstatic\.com/media/[^/]+\.[a-zA-Z]{3,4})(?:/v1/.*)?$"#
        ]

        for pattern in patterns {
            if let match = firstMatch(pattern: pattern, in: absolute), let upgraded = URL(string: match) {
                return upgraded
            }
        }

        return url
    }

    private func stripFragmentAndQuery(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.url ?? url
    }

    private func upgradeWordPressCandidates(in candidates: [URL: URL]) -> [URL: URL] {
        var upgraded: [URL: URL] = [:]
        let pattern = #"^(https?://[^/]+/wp-content/uploads/\d{4}/\d{2}/)(.+?)(-\d+x\d+)(\.[a-z]+)$"#

        for (url, referer) in candidates {
            let upgradedURL: URL
            if let match = firstCaptureGroups(pattern: pattern, in: url.absoluteString), match.count == 4,
               let originalURL = URL(string: match[0] + match[1] + match[3]) {
                upgradedURL = originalURL
            } else {
                upgradedURL = url
            }

            if let existingReferer = upgraded[upgradedURL] {
                if shouldPreferReferer(referer, over: existingReferer) {
                    upgraded[upgradedURL] = referer
                }
            } else {
                upgraded[upgradedURL] = referer
            }
        }

        return upgraded
    }

    private func selectLargestAssetVariants(from urls: Set<URL>) -> [URL] {
        var bestByKey: [String: (url: URL, score: Int)] = [:]

        for url in urls.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            let key = canonicalAssetKey(for: url)
            guard !key.isEmpty else { continue }

            let score = resolutionScore(for: url)
            if let existing = bestByKey[key] {
                if score > existing.score || (score == existing.score && shouldPrefer(url, over: existing.url)) {
                    bestByKey[key] = (url, score)
                }
            } else {
                bestByKey[key] = (url, score)
            }
        }

        return bestByKey.values
            .map(\.url)
            .sorted(by: { $0.absoluteString < $1.absoluteString })
    }

    private func canonicalAssetKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        let filteredQueryItems = (components.queryItems ?? []).filter { item in
            !isSizeVariantQueryItem(item.name)
        }

        components.queryItems = filteredQueryItems.isEmpty ? nil : filteredQueryItems.sorted(by: { $0.name < $1.name })
        components.fragment = nil

        let normalizedHost = (components.host ?? "").lowercased()
        let normalizedPath: String
        if normalizedHost == "freight.cargo.site" {
            normalizedPath = normalizedCargoAssetPath(components.percentEncodedPath)
        } else {
            normalizedPath = normalizedAssetPath(components.percentEncodedPath)
        }
        let normalizedQuery = components.percentEncodedQuery ?? ""
        return "\(components.scheme ?? "https")://\(normalizedHost)\(normalizedPath)?\(normalizedQuery)"
    }

    private func normalizedAssetPath(_ path: String) -> String {
        var normalized = path
        normalized = normalized.replacingOccurrences(
            of: #"-\d{2,5}x\d{2,5}(?=\.[a-zA-Z0-9]+$)"#,
            with: "",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([/_-])w[_=-]?\d{2,5}([,_-]|/)"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([/_-])h[_=-]?\d{2,5}([,_-]|/)"#,
            with: "$1",
            options: .regularExpression
        )
        return normalized
    }

    private func normalizedCargoAssetPath(_ path: String) -> String {
        if let captures = firstCaptureGroups(
            pattern: #"^/(?:w/\d+|t/original)/i/([^/]+)/(.+)$"#,
            in: path
        ), captures.count == 2 {
            return "/i/\(captures[0])/\(captures[1])"
        }

        return normalizedAssetPath(path)
    }

    private func isSizeVariantQueryItem(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let sizeKeys: Set<String> = [
            "w", "width", "h", "height", "dpr", "q", "quality", "fit", "crop",
            "fm", "format", "auto", "rect", "resize", "sz", "s"
        ]
        return sizeKeys.contains(lowered)
    }

    private func resolutionScore(for url: URL) -> Int {
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("freight.cargo.site/t/original/") {
            return Int.max / 4
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let width = dimensionValue(named: ["w", "width"], in: queryItems)
            ?? firstDimensionMatch(pattern: #"(?i)(?:^|[?&/_,-])w(?:idth)?[_=-]?(\d{2,5})"#, in: absolute)
        let height = dimensionValue(named: ["h", "height"], in: queryItems)
            ?? firstDimensionMatch(pattern: #"(?i)(?:^|[?&/_,-])h(?:eight)?[_=-]?(\d{2,5})"#, in: absolute)

        if let width, let height {
            return safeResolutionScore(width: width, height: height)
        }

        if let pair = firstResolutionPair(in: absolute) {
            return safeResolutionScore(width: pair.0, height: pair.1)
        }

        if let width {
            return safeResolutionScore(width: width, height: width)
        }

        if let height {
            return safeResolutionScore(width: height, height: height)
        }

        return 0
    }

    private func safeResolutionScore(width: Int, height: Int) -> Int {
        let normalizedWidth = max(0, width)
        let normalizedHeight = max(0, height)
        let (product, overflowed) = normalizedWidth.multipliedReportingOverflow(by: normalizedHeight)
        if overflowed {
            return Int.max / 8
        }
        return product
    }

    private func dimensionValue(named names: [String], in queryItems: [URLQueryItem]) -> Int? {
        let loweredNames = Set(names.map { $0.lowercased() })
        for item in queryItems where loweredNames.contains(item.name.lowercased()) {
            if let value = item.value, let number = Int(value) {
                return number
            }
        }
        return nil
    }

    private func firstDimensionMatch(pattern: String, in text: String) -> Int? {
        firstMatch(pattern: pattern, in: text).flatMap(Int.init)
    }

    private func firstResolutionPair(in text: String) -> (Int, Int)? {
        let patterns = [
            #"(?i)(\d{2,5})x(\d{2,5})(?=\.[a-z0-9]+(?:$|[?#]))"#,
            #"(?i)[?&](?:w|width)=(\d{2,5})[^\n]*?[?&](?:h|height)=(\d{2,5})"#
        ]

        for pattern in patterns {
            if let captures = firstCaptureGroups(pattern: pattern, in: text),
               captures.count >= 2,
               let width = Int(captures[0]),
               let height = Int(captures[1]) {
                return (width, height)
            }
        }

        return nil
    }

    private func shouldPrefer(_ candidate: URL, over existing: URL) -> Bool {
        let candidateComponents = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
        let existingComponents = URLComponents(url: existing, resolvingAgainstBaseURL: false)
        let candidateHasQuery = !(candidateComponents?.queryItems?.isEmpty ?? true)
        let existingHasQuery = !(existingComponents?.queryItems?.isEmpty ?? true)

        if existingHasQuery != candidateHasQuery {
            return !candidateHasQuery
        }

        return candidate.absoluteString.count < existing.absoluteString.count
    }

    private func shouldCrawlPage(url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.isEmpty || path == "/" {
            return true
        }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && nonPageExtensions.contains(ext) {
            return false
        }

        return true
    }

    private func shouldPreferReferer(_ candidate: URL, over existing: URL) -> Bool {
        refererPriority(for: candidate) > refererPriority(for: existing)
    }

    private func refererPriority(for url: URL) -> Int {
        let path = url.path.lowercased()
        if path.contains("{{") {
            return Int.min / 4
        }

        let lastComponent = url.deletingPathExtension().lastPathComponent.lowercased()
        if ["rss", "feed", "stylesheet"].contains(lastComponent) {
            return -100
        }

        if !shouldCrawlPage(url: url) {
            return -200
        }

        if path.isEmpty || path == "/" {
            return 0
        }

        return 100 + min(path.count, 200)
    }

    private func downloadCandidates(
        _ candidates: [AssetCandidate],
        maxImages: Int,
        outputDirectory: URL,
        downloadSmallImages: Bool,
        downloadVideos: Bool,
        organizeImagesBySourcePage: Bool,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> (downloaded: [URL], skippedSmall: Int, skippedLarge: Int, errors: Int) {
        var downloaded: [URL] = []
        var savedImageRecords: [SavedImageRecord] = []
        var savedVideoHashes = Set<String>()
        var skippedSmall = 0
        var skippedLarge = 0
        var errors = 0

        func persistImage(_ image: DownloadedImagePayload, duplicateOutcome: String) throws -> URL {
            guard !image.data.isEmpty else {
                throw PortfolioScraperError.emptyAsset(url: nil)
            }
            try FileManager.default.createDirectory(at: image.destinationDirectory, withIntermediateDirectories: true)
            let preferredName = if image.fingerprint != nil {
                filenameByAppendingDoneMarker(
                    to: image.preferredName,
                    duplicateOutcome: duplicateOutcome
                )
            } else {
                image.preferredName
            }
            let fileURL = try uniqueOutputURL(in: image.destinationDirectory, preferredName: preferredName)
            try Task.checkCancellation()
            try image.data.write(to: fileURL)
            return fileURL
        }

        for candidate in candidates {
            try Task.checkCancellation()
            if downloaded.count >= maxImages { break }
            do {
                let ext = candidate.url.pathExtension.lowercased()
                if videoExtensions.contains(ext) {
                    guard downloadVideos else {
                        await progress("Skipped video \(candidate.url.lastPathComponent) (Download videos is off)")
                        continue
                    }
                    let videoResult = try await downloadVideo(
                        from: candidate,
                        outputDirectory: outputDirectory,
                        organizeImagesBySourcePage: organizeImagesBySourcePage
                    )
                    switch videoResult {
                    case .downloaded(let video):
                        guard savedVideoHashes.insert(video.contentHash).inserted else {
                            await progress("Skipped exact duplicate video \(video.preferredName)")
                            continue
                        }
                        try FileManager.default.createDirectory(at: video.destinationDirectory, withIntermediateDirectories: true)
                        let fileURL = try uniqueOutputURL(in: video.destinationDirectory, preferredName: video.preferredName)
                        try Task.checkCancellation()
                        try video.data.write(to: fileURL)
                        downloaded.append(fileURL)
                        await progress("Saved video \(relativeOutputPath(for: fileURL, outputDirectory: outputDirectory))")
                    case .skippedLarge:
                        skippedLarge += 1
                    }
                } else {
                    let imageResult = try await downloadImage(
                        from: candidate,
                        outputDirectory: outputDirectory,
                        downloadSmallImages: downloadSmallImages,
                        organizeImagesBySourcePage: organizeImagesBySourcePage
                    )
                    switch imageResult {
                    case .downloaded(let image):
                        let fileURL: URL?

                        if let fingerprint = image.fingerprint {
                            if savedImageRecords.contains(where: { $0.contentHash == image.contentHash }) {
                                await progress("Skipped exact duplicate \(image.preferredName)")
                                fileURL = nil
                            } else {
                            let duplicateIndexes = savedImageRecords.indices.filter {
                                isNearDuplicate(fingerprint, savedImageRecords[$0].fingerprint)
                            }

                            if duplicateIndexes.isEmpty {
                                let savedURL = try persistImage(image, duplicateOutcome: "NOMATCH")
                                downloaded.append(savedURL)
                                savedImageRecords.append(SavedImageRecord(fileURL: savedURL, contentHash: image.contentHash, fingerprint: fingerprint))
                                fileURL = savedURL
                            } else if duplicateIndexes.contains(where: { savedImageRecords[$0].fingerprint.pixelArea >= fingerprint.pixelArea }) {
                                fileURL = nil
                            } else {
                                let duplicateURLs = Set(duplicateIndexes.map { savedImageRecords[$0].fileURL })
                                // Save the better variant first so an interrupted replacement
                                // can never erase the only archived copy.
                                let replacementURL = try persistImage(image, duplicateOutcome: "REPLACE")
                                for url in duplicateURLs where FileManager.default.fileExists(atPath: url.path) {
                                    try? FileManager.default.removeItem(at: url)
                                }
                                downloaded.removeAll { duplicateURLs.contains($0) }
                                savedImageRecords.removeAll { duplicateURLs.contains($0.fileURL) }
                                downloaded.append(replacementURL)
                                savedImageRecords.append(SavedImageRecord(fileURL: replacementURL, contentHash: image.contentHash, fingerprint: fingerprint))
                                fileURL = replacementURL
                            }
                            }
                        } else {
                            let savedURL = try persistImage(image, duplicateOutcome: "NOMATCH")
                            downloaded.append(savedURL)
                            if let fingerprint = image.fingerprint {
                                savedImageRecords.append(SavedImageRecord(fileURL: savedURL, contentHash: image.contentHash, fingerprint: fingerprint))
                            }
                            fileURL = savedURL
                        }

                        if let fileURL {
                            await progress("Saved \(image.width)x\(image.height) \(relativeOutputPath(for: fileURL, outputDirectory: outputDirectory))")
                        }
                    case .skippedSmall:
                        skippedSmall += 1
                    }
                }
            } catch {
                errors += 1
                await progress("Failed \(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (downloaded, skippedSmall, skippedLarge, errors)
    }

    private enum ImageDownloadResult {
        case downloaded(DownloadedImagePayload)
        case skippedSmall
    }

    private enum VideoDownloadResult {
        case downloaded(DownloadedVideoPayload)
        case skippedLarge
    }

    private func downloadImage(
        from candidate: AssetCandidate,
        outputDirectory: URL,
        downloadSmallImages: Bool,
        organizeImagesBySourcePage: Bool
    ) async throws -> ImageDownloadResult {
        try Task.checkCancellation()
        let assetResponse = try await fetchAsset(for: candidate)
        let data = assetResponse.data
        guard !data.isEmpty else {
            throw PortfolioScraperError.emptyAsset(url: candidate.url)
        }
        guard !isHTMLResponse(data: data, mimeType: assetResponse.mimeType) else {
            throw PortfolioScraperError.emptyAsset(url: candidate.url)
        }
        let mimeType = assetResponse.mimeType
        let preferredName = preferredFilename(for: candidate.url, mimeType: mimeType ?? "image/jpeg", fallback: "image")

        let analysisData: Data
        if isAVIF(url: candidate.url, mimeType: mimeType),
           let convertedPNG = try convertAVIFAnalysisCopyToPNG(data: data, outputDirectory: outputDirectory, preferredName: preferredName) {
            analysisData = convertedPNG
        } else {
            analysisData = data
        }

        let decodedImage = decodedImage(from: analysisData)
        let width = decodedImage?.width ?? 0
        let height = decodedImage?.height ?? 0

        if !downloadSmallImages && max(width, height) < minPixelSize {
            return .skippedSmall
        }
        let fingerprint = decodedImage.flatMap(imageFingerprint(for:))

        return .downloaded(
            DownloadedImagePayload(
                data: data,
                preferredName: preferredName,
                width: width,
                height: height,
                contentHash: contentHash(for: data),
                fingerprint: fingerprint,
                destinationDirectory: sourceDirectory(
                    for: candidate.referer,
                    in: outputDirectory,
                    organizeImagesBySourcePage: organizeImagesBySourcePage,
                    mediaKind: .image
                )
            )
        )
    }

    private func downloadVideo(
        from candidate: AssetCandidate,
        outputDirectory: URL,
        organizeImagesBySourcePage: Bool
    ) async throws -> VideoDownloadResult {
        try Task.checkCancellation()
        let headRequest = makeRequest(url: candidate.url, method: "HEAD", referer: candidate.referer)
        if let (_, response) = try? await dataWithTransientRetry(for: headRequest),
           let httpResponse = response as? HTTPURLResponse,
           let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(contentLength),
           length > maxVideoBytes {
            return .skippedLarge
        }

        let assetResponse = try await fetchAsset(for: candidate)
        let data = assetResponse.data
        guard !data.isEmpty else {
            throw PortfolioScraperError.emptyAsset(url: candidate.url)
        }
        guard !isHTMLResponse(data: data, mimeType: assetResponse.mimeType) else {
            throw PortfolioScraperError.emptyAsset(url: candidate.url)
        }

        guard data.count <= maxVideoBytes else {
            return .skippedLarge
        }

        return .downloaded(
            DownloadedVideoPayload(
                data: data,
                preferredName: preferredFilename(for: candidate.url, mimeType: assetResponse.mimeType ?? "video/mp4", fallback: "video"),
                contentHash: contentHash(for: data),
                destinationDirectory: sourceDirectory(
                    for: candidate.referer,
                    in: outputDirectory,
                    organizeImagesBySourcePage: organizeImagesBySourcePage,
                    mediaKind: .video
                )
            )
        )
    }

    private func fetchAsset(for candidate: AssetCandidate) async throws -> AssetResponse {
        let request = makeRequest(url: candidate.url, referer: candidate.referer)

        do {
            let (data, response) = try await dataWithTransientRetry(for: request)
            let httpResponse = try validateSuccessfulHTTP(response, fallbackURL: candidate.url)
            guard !data.isEmpty else {
                throw PortfolioScraperError.emptyAsset(url: candidate.url)
            }
            return AssetResponse(
                data: data,
                mimeType: httpResponse.value(forHTTPHeaderField: "Content-Type")
            )
        } catch let error as PortfolioScraperError {
            if case .httpStatus(let code, _) = error, code == 403 {
                do {
                    return try await curlFetchAsset(for: candidate)
                } catch let curlError as PortfolioScraperError {
                    if case .httpStatus(let curlCode, _) = curlError,
                       curlCode == 403,
                       shouldUseRenderedImageFetch(for: candidate.url) {
                        let renderedAsset = try await RenderedPageCrawler.fetchImageAssetViaDOM(
                            url: candidate.url,
                            refererPageURL: candidate.referer
                        )
                        guard !renderedAsset.data.isEmpty else {
                            throw PortfolioScraperError.emptyAsset(url: candidate.url)
                        }
                        return AssetResponse(data: renderedAsset.data, mimeType: renderedAsset.mimeType)
                    }
                    throw curlError
                }
            }
            throw error
        } catch where shouldUseRenderedImageFetch(for: candidate.url) {
            let renderedAsset = try await RenderedPageCrawler.fetchImageAssetViaDOM(
                url: candidate.url,
                refererPageURL: candidate.referer
            )
            guard !renderedAsset.data.isEmpty else {
                throw PortfolioScraperError.emptyAsset(url: candidate.url)
            }
            return AssetResponse(data: renderedAsset.data, mimeType: renderedAsset.mimeType)
        }
    }

    private func shouldUseRenderedImageFetch(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private func curlFetchAsset(for candidate: AssetCandidate) async throws -> AssetResponse {
        do {
            return try await curlFetchAsset(for: candidate, referer: candidate.referer)
        } catch let error as PortfolioScraperError {
            if case .httpStatus(let code, _) = error,
               code == 403,
               candidate.referer != nil,
               candidate.url.host?.lowercased() == "freight.cargo.site" {
                return try await curlFetchAsset(for: candidate, referer: nil)
            }
            throw error
        }
    }

    private func curlFetchAsset(for candidate: AssetCandidate, referer: URL?) async throws -> AssetResponse {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        let bodyURL = temporaryDirectory.appendingPathComponent("folio-curl-\(identifier).body")
        let headerURL = temporaryDirectory.appendingPathComponent("folio-curl-\(identifier).headers")

        defer {
            try? FileManager.default.removeItem(at: bodyURL)
            try? FileManager.default.removeItem(at: headerURL)
        }

        var arguments = [
            "-L",
            "-f",
            "--silent",
            "--show-error",
            "-A", browserUserAgent,
            "-D", headerURL.path,
            "-o", bodyURL.path
        ]

        if let referer {
            arguments.append(contentsOf: ["-H", "Referer: \(referer.absoluteString)"])
            if candidate.url.host == referer.host,
               let scheme = referer.scheme,
               let host = referer.host {
                arguments.append(contentsOf: ["-H", "Origin: \(scheme)://\(host)"])
            }
        }

        if candidate.url.host?.lowercased() == "freight.cargo.site",
           imageExtensions.contains(candidate.url.pathExtension.lowercased()) {
            arguments.append(contentsOf: [
                "-H", "Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                "-H", "Accept-Language: en-GB,en-US;q=0.9,en;q=0.8",
                "-H", "Sec-Fetch-Dest: image",
                "-H", "Sec-Fetch-Mode: no-cors",
                "-H", "Sec-Fetch-Site: cross-site",
                "-H", "Priority: i"
            ])
        }

        arguments.append(candidate.url.absoluteString)

        let status = try await runCurl(arguments: arguments)
        let headers = (try? String(contentsOf: headerURL, encoding: .utf8)) ?? ""
        if let httpStatus = lastHTTPStatusCode(in: headers),
           !(200..<400).contains(httpStatus) {
            throw PortfolioScraperError.httpStatus(code: httpStatus, url: candidate.url)
        }
        guard status == 0 else {
            throw PortfolioScraperError.httpStatus(code: 403, url: candidate.url)
        }

        let data = try Data(contentsOf: bodyURL)
        guard !data.isEmpty else {
            throw PortfolioScraperError.emptyAsset(url: candidate.url)
        }
        let mimeType = lastHeaderValue(named: "Content-Type", in: headers)
        return AssetResponse(data: data, mimeType: mimeType)
    }

    private func runCurl(arguments: [String]) async throws -> Int32 {
        final class ResumeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            var callback: (@Sendable (Result<Int32, Error>) -> Void)?

            func resume(_ result: Result<Int32, Error>) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                let callback = callback
                lock.unlock()
                callback?(result)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let resumeBox = ResumeBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumeBox.callback = { result in
                    switch result {
                    case .success(let status):
                        continuation.resume(returning: status)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                process.terminationHandler = { process in
                    resumeBox.resume(.success(process.terminationStatus))
                }

                do {
                    try process.run()
                } catch {
                    resumeBox.resume(.failure(error))
                    return
                }

                Task {
                    try? await Task.sleep(for: curlTimeout)
                    if process.isRunning {
                        process.terminate()
                    }
                    resumeBox.resume(
                        .failure(
                            PortfolioScraperError.timedOut(
                                step: "curl download",
                                seconds: Int(curlTimeout.components.seconds)
                            )
                        )
                    )
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            resumeBox.resume(.failure(CancellationError()))
        }
    }

    private func lastHeaderValue(named name: String, in headers: String) -> String? {
        let blocks = headers.components(separatedBy: "\r\n\r\n").reversed()
        for block in blocks {
            for line in block.components(separatedBy: .newlines) {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                if key.caseInsensitiveCompare(name) == .orderedSame {
                    return line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private func lastHTTPStatusCode(in headers: String) -> Int? {
        let blocks = headers.components(separatedBy: "\r\n\r\n").reversed()
        for block in blocks {
            guard let statusLine = block.components(separatedBy: .newlines).first else { continue }
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else { continue }
            return code
        }
        return nil
    }

    private func validateSuccessfulHTTP(_ response: URLResponse, fallbackURL: URL) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PortfolioScraperError.httpStatus(code: httpResponse.statusCode, url: response.url ?? fallbackURL)
        }

        return httpResponse
    }

    private func decodedImage(from data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }

        if let image = NSImage(data: data) {
            var proposedRect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        }

        return nil
    }

    private func contentHash(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isHTMLResponse(data: Data, mimeType: String?) -> Bool {
        if mimeType?.lowercased().contains("text/html") == true ||
            mimeType?.lowercased().contains("application/xhtml") == true {
            return true
        }

        let prefix = String(data: data.prefix(512), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }

    private func isAVIF(url: URL, mimeType: String?) -> Bool {
        if url.pathExtension.lowercased() == "avif" {
            return true
        }

        guard let mimeType else { return false }
        return mimeType.lowercased().contains("avif")
    }

    private func convertAVIFAnalysisCopyToPNG(data: Data, outputDirectory: URL, preferredName: String) throws -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let pngName = URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent + ".png"
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let pngURL = try uniqueOutputURL(in: temporaryDirectory, preferredName: pngName)

        guard let destination = CGImageDestinationCreateWithURL(
            pngURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: pngURL)
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: pngURL)
        }

        return try Data(contentsOf: pngURL)
    }

    private func imageFingerprint(for image: CGImage) -> ImageFingerprint? {
        guard let normalizedImage = normalizedBitmapImage(from: image),
              let structureHash = perceptualDifferenceHash(for: normalizedImage),
              let colorHash = perceptualColorHash(for: normalizedImage),
              let colorSignature = coarseColorSignature(for: normalizedImage) else {
            return nil
        }

        return ImageFingerprint(
            structureHash: structureHash,
            colorSignature: colorSignature,
            redHash: colorHash.red,
            greenHash: colorHash.green,
            blueHash: colorHash.blue,
            width: normalizedImage.width,
            height: normalizedImage.height
        )
    }

    private func normalizedBitmapImage(from image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private func sampledPixels(for image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func perceptualDifferenceHash(for image: CGImage) -> UInt64? {
        let width = 9
        let height = 8

        guard let pixels = sampledPixels(for: image, width: width, height: height) else {
            return nil
        }

        var hash: UInt64 = 0
        var bitIndex: UInt64 = 0

        for row in 0..<height {
            for column in 0..<(width - 1) {
                let leftIndex = (row * width + column) * 4
                let rightIndex = (row * width + column + 1) * 4

                let left = luminance(
                    red: pixels[leftIndex],
                    green: pixels[leftIndex + 1],
                    blue: pixels[leftIndex + 2]
                )
                let right = luminance(
                    red: pixels[rightIndex],
                    green: pixels[rightIndex + 1],
                    blue: pixels[rightIndex + 2]
                )

                if left >= right {
                    hash |= UInt64(1) << bitIndex
                }
                bitIndex += 1
            }
        }

        return hash
    }

    private func coarseColorSignature(for image: CGImage) -> [UInt8]? {
        let sampleSize = 4
        guard let pixels = sampledPixels(for: image, width: sampleSize, height: sampleSize) else {
            return nil
        }

        var signature: [UInt8] = []
        signature.reserveCapacity(sampleSize * sampleSize * 3)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            signature.append(pixels[index])
            signature.append(pixels[index + 1])
            signature.append(pixels[index + 2])
        }

        return signature
    }

    private func perceptualColorHash(for image: CGImage) -> (red: UInt64, green: UInt64, blue: UInt64)? {
        let sampleSize = 8
        guard let pixels = sampledPixels(for: image, width: sampleSize, height: sampleSize) else {
            return nil
        }

        var redValues: [UInt8] = []
        var greenValues: [UInt8] = []
        var blueValues: [UInt8] = []
        redValues.reserveCapacity(sampleSize * sampleSize)
        greenValues.reserveCapacity(sampleSize * sampleSize)
        blueValues.reserveCapacity(sampleSize * sampleSize)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            redValues.append(pixels[index])
            greenValues.append(pixels[index + 1])
            blueValues.append(pixels[index + 2])
        }

        return (
            channelHash(from: redValues),
            channelHash(from: greenValues),
            channelHash(from: blueValues)
        )
    }

    private func channelHash(from values: [UInt8]) -> UInt64 {
        let average = values.reduce(0) { $0 + Int($1) } / max(values.count, 1)
        var hash: UInt64 = 0

        for (index, value) in values.enumerated() where Int(value) >= average {
            hash |= UInt64(1) << UInt64(index)
        }

        return hash
    }

    private func isNearDuplicate(_ lhs: ImageFingerprint, _ rhs: ImageFingerprint) -> Bool {
        let structureDistance = hammingDistance(lhs.structureHash, rhs.structureHash)
        let colorDistance = averageColorDistance(lhs.colorSignature, rhs.colorSignature)
        let aspectRatioDifference = abs(
            (Double(lhs.width) / Double(max(lhs.height, 1))) -
            (Double(rhs.width) / Double(max(rhs.height, 1)))
        )

        // Design work often deliberately reuses a layout with different colours. Only
        // collapse near-identical rendered pixels, not images that merely share a form.
        return structureDistance <= 7 && colorDistance <= 19 && aspectRatioDifference <= 0.01
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
    }

    private func averageColorDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return Int.max
        }

        let totalDifference = zip(lhs, rhs).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return totalDifference / lhs.count
    }

    private func luminance(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        (299 * Int(red) + 587 * Int(green) + 114 * Int(blue)) / 1000
    }

    private func preferredFilename(for url: URL, mimeType: String, fallback: String) -> String {
        let decodedBaseName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        let baseName = decodedBaseName.isEmpty ? fallback : decodedBaseName
        let ext = if !url.pathExtension.isEmpty {
            url.pathExtension
        } else if let uti = UTType(mimeType: mimeType), let preferred = uti.preferredFilenameExtension {
            preferred
        } else {
            fallback == "video" ? "mp4" : "jpg"
        }

        return "\(baseName).\(ext)"
    }

    private func sourceDirectory(
        for pageURL: URL?,
        in mediaDirectory: URL,
        organizeImagesBySourcePage: Bool,
        mediaKind: MediaKind
    ) -> URL {
        guard organizeImagesBySourcePage else {
            return mediaDirectory.appendingPathComponent(mediaKind.folderName, isDirectory: true)
        }

        var directory = mediaDirectory

        if let host = pageURL?.host?.replacingOccurrences(of: "www.", with: ""),
           !host.isEmpty {
            directory.appendPathComponent(sanitizeBaseName(host), isDirectory: true)
        } else {
            directory.appendPathComponent("Unknown Source", isDirectory: true)
        }

        let pathComponents = pageURL?.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map { $0.removingPercentEncoding ?? $0 } ?? []

        if pathComponents.isEmpty {
            directory.appendPathComponent("Home", isDirectory: true)
            return directory
        }

        for component in pathComponents {
            directory.appendPathComponent(sanitizeBaseName(component), isDirectory: true)
        }

        return directory
    }

    private func relativeOutputPath(for fileURL: URL, outputDirectory: URL) -> String {
        let prefix = outputDirectory.path.hasSuffix("/") ? outputDirectory.path : outputDirectory.path + "/"
        if fileURL.path.hasPrefix(prefix) {
            return String(fileURL.path.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private func uniqueOutputURL(in directory: URL, preferredName: String) throws -> URL {
        let sanitized = sanitizedFilename(from: preferredName)
        let fileURL = URL(fileURLWithPath: sanitized)
        let ext = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let duplicateBase = truncatedBaseName(
                baseName,
                extensionLength: ext.count,
                suffixLength: " \(index)".count
            )
            let nextName = ext.isEmpty ? "\(duplicateBase) \(index)" : "\(duplicateBase) \(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }

        return candidate
    }

    private func sanitizedFilename(from preferredName: String) -> String {
        let parsed = URL(fileURLWithPath: preferredName.precomposedStringWithCanonicalMapping)
        let fallbackBase = "file"
        let cleanedExtension = sanitizeExtension(parsed.pathExtension)
        let cleanedBase = sanitizeBaseName(parsed.deletingPathExtension().lastPathComponent)
        let effectiveBase = cleanedBase.isEmpty ? fallbackBase : cleanedBase
        let truncatedBase = truncatedBaseName(effectiveBase, extensionLength: cleanedExtension.count, suffixLength: 0)
        return cleanedExtension.isEmpty ? truncatedBase : "\(truncatedBase).\(cleanedExtension)"
    }

    private func filenameByAppendingDoneMarker(
        to preferredName: String,
        duplicateOutcome: String
    ) -> String {
        let fileURL = URL(fileURLWithPath: preferredName)
        let ext = fileURL.pathExtension
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let marker = "DONE-CHECKON-\(duplicateOutcome)"
        if ext.isEmpty {
            return "\(baseName) \(marker)"
        }
        return "\(baseName) \(marker).\(ext)"
    }

    private func sanitizeBaseName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let replaced = value.unicodeScalars.map { scalar -> Character in
            invalidCharacters.contains(scalar) ? "-" : Character(scalar)
        }

        let collapsed = String(replaced)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -_"))

        return collapsed.isEmpty ? "file" : collapsed
    }

    private func sanitizeExtension(_ value: String) -> String {
        let cleaned = value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
        return String(cleaned.prefix(10))
    }

    private func truncatedBaseName(_ value: String, extensionLength: Int, suffixLength: Int) -> String {
        let reservedLength = (extensionLength > 0 ? extensionLength + 1 : 0) + suffixLength
        let maxBaseLength = max(1, maxFilenameLength - reservedLength)
        let truncated = String(value.prefix(maxBaseLength)).trimmingCharacters(in: CharacterSet(charactersIn: ". -_"))
        return truncated.isEmpty ? "file" : truncated
    }

    private func attributeValues(named attribute: String, in html: String) -> [String] {
        regexMatches(
            pattern: #"\b\#(attribute)\s*=\s*["']([^"']+)["']"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }

    private func regexMatches(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        regexMatches(pattern: pattern, in: text, options: [.caseInsensitive]).first
    }

    private func firstCaptureGroups(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[captureRange])
        }
    }
}
