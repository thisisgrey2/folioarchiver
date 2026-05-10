import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ScrapeResult: Sendable {
    let studio: String
    let outputDirectory: URL
    let foundCandidates: Int
    let downloaded: [URL]
    let skippedSmall: Int
    let skippedLarge: Int
    let errors: Int
    let platform: String
}

private enum PortfolioScraperError: LocalizedError {
    case httpStatus(code: Int, url: URL?)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let url):
            if let url {
                return "HTTP \(code) for \(url.absoluteString)"
            }
            return "HTTP \(code)"
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

private struct ImageFingerprint {
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
    var fingerprint: ImageFingerprint
}

actor PortfolioScraperService {
    private let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let maxVideoBytes = 50 * 1024 * 1024
    private let maxCrawlPages = 40
    private let minPixelSize = 1100
    private let maxFilenameLength = 120
    private let skipKeywords = ["favicon", "avatar", "1x1", "blank", "spacer", "logo", "icon"]
    private let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "avif"])
    private let videoExtensions = Set(["mp4", "mov", "webm", "m4v", "ogv"])
    private let stripQueryPrefixes = [
        "https://www.datocms-assets.com/",
        "https://images.datocms-assets.com/",
        "https://images.ctfassets.net/",
        "https://cdn.sanity.io/"
    ]
    private let skipLinkPatterns = [
        "/about", "/contact", "/privacy", "/legal", "/terms",
        "/policy", "/jobs", "/careers", "/feed", "/tag/", "/category/"
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

    func scrape(
        startURL: URL,
        maxImages: Int,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> ScrapeResult {
        try Task.checkCancellation()
        let normalizedStartURL = normalizedStartURL(from: startURL)
        let studio = studioName(from: normalizedStartURL)
        let outputDirectory = desktopDirectory().appendingPathComponent(studio, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var crawled = Set<URL>()
        var toCrawl = [normalizedStartURL]
        var allCandidates: [URL: URL] = [:]
        var isCargo = false

        while let url = toCrawl.first, crawled.count < maxCrawlPages {
            try Task.checkCancellation()
            toCrawl.removeFirst()
            guard crawled.insert(url).inserted else { continue }

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

                let htmlLinks = extractInternalLinks(from: snapshot.html, baseURL: normalizedStartURL)
                let domLinks = normalizedInternalLinks(from: snapshot.internalLinkCandidates, siteURL: normalizedStartURL)
                enqueueDiscoveredLinks(Array(Set(htmlLinks + domLinks)), crawled: crawled, pending: &toCrawl)

                if url == normalizedStartURL {
                    let slugLinks = await extractSlugLinks(from: snapshot.html, baseURL: normalizedStartURL)
                    enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                }
            } catch {
                await progress("Rendered crawl failed for \(url.absoluteString): \(error.localizedDescription)")

                do {
                    let (html, finalURL) = try await fetchString(from: url)
                    mergeCandidates(
                        extractCandidates(from: html, baseURL: finalURL),
                        sourcePage: finalURL,
                        into: &allCandidates
                    )

                    let internalLinks = extractInternalLinks(from: html, baseURL: normalizedStartURL)
                    enqueueDiscoveredLinks(internalLinks, crawled: crawled, pending: &toCrawl)

                    if url == normalizedStartURL {
                        let slugLinks = await extractSlugLinks(from: html, baseURL: normalizedStartURL)
                        enqueueDiscoveredLinks(slugLinks, crawled: crawled, pending: &toCrawl)
                    }
                } catch {
                    await progress("Failed to crawl \(url.absoluteString): \(error.localizedDescription)")
                }
            }
        }

        let upgradedCandidates = upgradeWordPressURLs(in: Set(allCandidates.keys))
        var referersByURL: [URL: URL] = [:]
        for url in upgradedCandidates {
            if let referer = allCandidates[url] {
                referersByURL[url] = referer
            }
        }
        let deduped = selectLargestAssetVariants(from: upgradedCandidates).map {
            AssetCandidate(url: $0, referer: referersByURL[$0])
        }
        await progress("Found \(deduped.count) candidate files")

        let downloadResult = try await downloadCandidates(
            deduped,
            maxImages: maxImages,
            outputDirectory: outputDirectory,
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
            platform: isCargo ? "Cargo (Rendered web crawl)" : "Rendered web crawl"
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

    private func studioName(from url: URL) -> String {
        let host = (url.host ?? "portfolio").lowercased().replacingOccurrences(of: "www.", with: "")
        let studio = host.split(separator: ".").first.map(String.init) ?? "portfolio"
        let sanitized = studio.replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        return sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "portfolio" : sanitized
    }

    private func fetchString(from url: URL) async throws -> (String, URL) {
        let request = makeRequest(url: url)
        let (data, response) = try await session.data(for: request)
        _ = try validateSuccessfulHTTP(response, fallbackURL: url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }
        return (html, response.url ?? url)
    }

    private func makeRequest(url: URL, method: String = "GET", referer: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = referer.scheme, let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        return request
    }

    private func extractCandidates(from html: String, baseURL: URL) -> Set<URL> {
        var found = Set<URL>()

        insertAttributeCandidates(
            named: ["src", "data-src", "data-lazy-src", "data-original", "poster"],
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertSrcsetCandidates(
            named: ["srcset", "data-srcset"],
            from: html,
            baseURL: baseURL,
            into: &found
        )
        insertRegexMatches(
            pattern: #"url\(["']?(https://[^"')\s]+)["']?\)"#,
            from: html,
            baseURL: baseURL,
            into: &found
        )
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

        return found
    }

    private func extractInternalLinks(from html: String, baseURL: URL) -> [URL] {
        return attributeValues(named: "href", in: html)
            .compactMap { crawlableInternalURL(from: $0, baseURL: baseURL, siteURL: baseURL) }
    }

    private func normalizedAssetCandidates(from rawCandidates: [String], baseURL: URL) -> Set<URL> {
        Set(rawCandidates.compactMap { normalize(candidate: $0, baseURL: baseURL) })
    }

    private func mergeCandidates(_ urls: Set<URL>, sourcePage: URL, into candidates: inout [URL: URL]) {
        for url in urls where candidates[url] == nil {
            candidates[url] = sourcePage
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

    private func insertCandidate(_ rawValue: String, baseURL: URL, into found: inout Set<URL>) {
        if let normalized = normalize(candidate: rawValue, baseURL: baseURL) {
            found.insert(normalized)
        }
    }

    private func crawlableInternalURL(from rawValue: String, baseURL: URL, siteURL: URL) -> URL? {
        let origin = "\(siteURL.scheme ?? "https")://\(siteURL.host ?? "")"
        guard let normalized = normalize(candidate: rawValue, baseURL: baseURL) else { return nil }
        guard normalized.absoluteString.hasPrefix(origin) else { return nil }
        guard normalized.absoluteString != siteURL.absoluteString else { return nil }
        let lowered = normalized.absoluteString.lowercased()
        guard !skipLinkPatterns.contains(where: lowered.contains) else { return nil }
        guard shouldCrawlPage(url: normalized) else { return nil }
        return stripFragmentAndQuery(from: normalized)
    }

    private func enqueueDiscoveredLinks(_ links: [URL], crawled: Set<URL>, pending: inout [URL]) {
        for link in links {
            if crawled.contains(link) || pending.contains(link) {
                continue
            }
            pending.append(link)
        }
    }

    private func extractSlugLinks(from html: String, baseURL: URL) async -> [URL] {
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

        for slug in Array(Set(slugs)).prefix(12) {
            for template in slugTemplates {
                let path = pathPrefix + String(format: template, slug)
                guard let candidate = URL(string: "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(path)") else {
                    continue
                }

                do {
                    let request = makeRequest(url: candidate, method: "HEAD")
                    let (_, response) = try await session.data(for: request)
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

    private func normalize(candidate rawValue: String, baseURL: URL) -> URL? {
        guard !rawValue.isEmpty else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlDecoded = decodeHTMLEntities(in: trimmed)
        let lowered = htmlDecoded.lowercased()
        guard !lowered.hasPrefix("data:"),
              !lowered.hasPrefix("blob:"),
              !lowered.hasPrefix("mailto:"),
              !lowered.hasPrefix("tel:"),
              !lowered.hasPrefix("javascript:") else {
            return nil
        }

        let extracted = extractNextImageURL(from: htmlDecoded)
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

    private func upgradeWordPressURLs(in urls: Set<URL>) -> Set<URL> {
        var upgraded = Set<URL>()
        let pattern = #"^(https?://[^/]+/wp-content/uploads/\d{4}/\d{2}/)(.+?)(-\d+x\d+)(\.[a-z]+)$"#

        for url in urls {
            if let match = firstCaptureGroups(pattern: pattern, in: url.absoluteString), match.count == 4,
               let upgradedURL = URL(string: match[0] + match[1] + match[3]) {
                upgraded.insert(upgradedURL)
            } else {
                upgraded.insert(url)
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
        let normalizedPath = normalizedAssetPath(components.percentEncodedPath)
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
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let width = dimensionValue(named: ["w", "width"], in: queryItems)
            ?? firstDimensionMatch(pattern: #"(?i)(?:^|[?&/_,-])w(?:idth)?[_=-]?(\d{2,5})"#, in: absolute)
        let height = dimensionValue(named: ["h", "height"], in: queryItems)
            ?? firstDimensionMatch(pattern: #"(?i)(?:^|[?&/_,-])h(?:eight)?[_=-]?(\d{2,5})"#, in: absolute)

        if let width, let height {
            return width * height
        }

        if let pair = firstResolutionPair(in: absolute) {
            return pair.0 * pair.1
        }

        if let width {
            return width * width
        }

        if let height {
            return height * height
        }

        return 0
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

    private func downloadCandidates(
        _ candidates: [AssetCandidate],
        maxImages: Int,
        outputDirectory: URL,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> (downloaded: [URL], skippedSmall: Int, skippedLarge: Int, errors: Int) {
        var downloaded: [URL] = []
        var savedImageRecords: [SavedImageRecord] = []
        var skippedSmall = 0
        var skippedLarge = 0
        var errors = 0

        for candidate in candidates {
            try Task.checkCancellation()
            if downloaded.count >= maxImages { break }
            if shouldSkip(url: candidate.url) { continue }

            do {
                let ext = candidate.url.pathExtension.lowercased()
                if videoExtensions.contains(ext) {
                    let videoResult = try await downloadVideo(from: candidate, outputDirectory: outputDirectory)
                    switch videoResult {
                    case .downloaded(let fileURL):
                        downloaded.append(fileURL)
                        await progress("Saved video \(fileURL.lastPathComponent)")
                    case .skippedLarge:
                        skippedLarge += 1
                    }
                } else {
                    let imageResult = try await downloadImage(from: candidate, outputDirectory: outputDirectory)
                    switch imageResult {
                    case .downloaded(let fileURL, let width, let height, let fingerprint, _):
                        if let fingerprint,
                           let duplicateIndex = savedImageRecords.firstIndex(where: { isNearDuplicate(fingerprint, $0.fingerprint) }) {
                            let existing = savedImageRecords[duplicateIndex]
                            if fingerprint.pixelArea > existing.fingerprint.pixelArea {
                                try? FileManager.default.removeItem(at: existing.fileURL)
                                if let downloadedIndex = downloaded.firstIndex(of: existing.fileURL) {
                                    downloaded[downloadedIndex] = fileURL
                                } else {
                                    downloaded.append(fileURL)
                                }
                                savedImageRecords[duplicateIndex] = SavedImageRecord(fileURL: fileURL, fingerprint: fingerprint)
                            } else {
                                try? FileManager.default.removeItem(at: fileURL)
                            }
                        } else {
                            downloaded.append(fileURL)
                            if let fingerprint {
                                savedImageRecords.append(SavedImageRecord(fileURL: fileURL, fingerprint: fingerprint))
                            }
                            await progress("Saved \(width)x\(height) \(fileURL.lastPathComponent)")
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
        case downloaded(URL, Int, Int, ImageFingerprint?, String?)
        case skippedSmall
    }

    private enum VideoDownloadResult {
        case downloaded(URL)
        case skippedLarge
    }

    private func downloadImage(from candidate: AssetCandidate, outputDirectory: URL) async throws -> ImageDownloadResult {
        try Task.checkCancellation()
        let assetResponse = try await fetchAsset(for: candidate)
        let data = assetResponse.data
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

        if width < minPixelSize && height < minPixelSize {
            return .skippedSmall
        }
        let fingerprint = decodedImage.flatMap(imageFingerprint(for:))

        let fileURL = try uniqueOutputURL(
            in: outputDirectory,
            preferredName: preferredName
        )
        try Task.checkCancellation()
        try data.write(to: fileURL)
        return .downloaded(fileURL, width, height, fingerprint, mimeType)
    }

    private func downloadVideo(from candidate: AssetCandidate, outputDirectory: URL) async throws -> VideoDownloadResult {
        try Task.checkCancellation()
        let headRequest = makeRequest(url: candidate.url, method: "HEAD", referer: candidate.referer)
        if let (_, response) = try? await session.data(for: headRequest),
           let httpResponse = response as? HTTPURLResponse,
           let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(contentLength),
           length > maxVideoBytes {
            return .skippedLarge
        }

        let assetResponse = try await fetchAsset(for: candidate)
        let data = assetResponse.data

        guard data.count <= maxVideoBytes else {
            return .skippedLarge
        }

        let fileURL = try uniqueOutputURL(
            in: outputDirectory,
            preferredName: preferredFilename(for: candidate.url, mimeType: assetResponse.mimeType ?? "video/mp4", fallback: "video")
        )
        try Task.checkCancellation()
        try data.write(to: fileURL)
        return .downloaded(fileURL)
    }

    private func fetchAsset(for candidate: AssetCandidate) async throws -> AssetResponse {
        let request = makeRequest(url: candidate.url, referer: candidate.referer)

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try validateSuccessfulHTTP(response, fallbackURL: candidate.url)
            return AssetResponse(
                data: data,
                mimeType: httpResponse.value(forHTTPHeaderField: "Content-Type")
            )
        } catch let error as PortfolioScraperError {
            if case .httpStatus(let code, _) = error, code == 403 {
                return try await curlFetchAsset(for: candidate)
            }
            throw error
        }
    }

    private func curlFetchAsset(for candidate: AssetCandidate) async throws -> AssetResponse {
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
            "--silent",
            "--show-error",
            "-A", browserUserAgent,
            "-D", headerURL.path,
            "-o", bodyURL.path
        ]

        if let referer = candidate.referer {
            arguments.append(contentsOf: ["-H", "Referer: \(referer.absoluteString)"])
            if let scheme = referer.scheme, let host = referer.host {
                arguments.append(contentsOf: ["-H", "Origin: \(scheme)://\(host)"])
            }
        }

        arguments.append(candidate.url.absoluteString)

        let status = try await runCurl(arguments: arguments)
        guard status == 0 else {
            throw PortfolioScraperError.httpStatus(code: 403, url: candidate.url)
        }

        let data = try Data(contentsOf: bodyURL)
        let headers = (try? String(contentsOf: headerURL, encoding: .utf8)) ?? ""
        let mimeType = lastHeaderValue(named: "Content-Type", in: headers)
        return AssetResponse(data: data, mimeType: mimeType)
    }

    private func runCurl(arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
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
              let colorHash = perceptualColorHash(for: normalizedImage) else {
            return nil
        }

        return ImageFingerprint(
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

    private func perceptualColorHash(for image: CGImage) -> (red: UInt64, green: UInt64, blue: UInt64)? {
        let sampleSize = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)

        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

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
        let redDistance = hammingDistance(lhs.redHash, rhs.redHash)
        let greenDistance = hammingDistance(lhs.greenHash, rhs.greenHash)
        let blueDistance = hammingDistance(lhs.blueHash, rhs.blueHash)
        return redDistance <= 12 && greenDistance <= 12 && blueDistance <= 12
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
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

    private func shouldSkip(url: URL) -> Bool {
        let lowered = url.absoluteString.lowercased()
        return skipKeywords.contains(where: lowered.contains) || lowered.hasSuffix(".svg") || lowered.hasSuffix(".ico")
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
