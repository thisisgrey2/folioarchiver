import AppKit
import Foundation
import WebKit

private enum RenderedPageCrawlerError: LocalizedError {
    case stepFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .stepFailed(let step, let message):
            return "\(step): \(message)"
        }
    }
}

struct RenderedPageSnapshot: Sendable {
    let finalURL: URL
    let html: String
    let assetCandidates: [String]
    let internalLinkCandidates: [String]
}

struct RenderedAssetResponse: Sendable {
    let data: Data
    let mimeType: String?
}

@MainActor
final class RenderedPageCrawler: NSObject {
    private let viewportSize = CGSize(width: 1440, height: 2200)
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    static func capture(url: URL) async throws -> RenderedPageSnapshot {
        let crawler = RenderedPageCrawler()
        return try await crawler.snapshot(url: url)
    }

    static func fetchAsset(url: URL, refererPageURL: URL?) async throws -> RenderedAssetResponse {
        let crawler = RenderedPageCrawler()
        return try await crawler.fetchAsset(url: url, refererPageURL: refererPageURL)
    }

    static func fetchImageAssetViaDOM(url: URL, refererPageURL: URL?) async throws -> RenderedAssetResponse {
        let crawler = RenderedPageCrawler()
        return try await crawler.fetchImageAssetViaDOM(url: url, refererPageURL: refererPageURL)
    }

    func snapshot(url: URL) async throws -> RenderedPageSnapshot {
        let webView = try prepareWebView()
        try await load(url: url, in: webView)
        try await settlePage(in: webView)
        try? await autoScroll(in: webView)
        try? await activateVideoContent(in: webView)
        try? await autoScroll(in: webView)

        let finalURL = webView.url ?? url
        let html = (try? await evaluateString(in: webView, script: Self.htmlSnapshotScript)) ?? ""
        let payload = (try? await evaluateJSON(in: webView, script: Self.assetAndLinkSnapshotScript)) ?? [:]
        let rawAssets = payload["assets"] as? [String] ?? []
        let rawLinks = payload["links"] as? [String] ?? []

        return RenderedPageSnapshot(
            finalURL: finalURL,
            html: html,
            assetCandidates: rawAssets,
            internalLinkCandidates: rawLinks
        )
    }

    func fetchAsset(url: URL, refererPageURL: URL?) async throws -> RenderedAssetResponse {
        let webView = try prepareWebView()
        if let refererPageURL {
            try await load(url: refererPageURL, in: webView)
            try await settlePage(in: webView)
        }

        let assetURLLiteral = Self.javascriptStringLiteral(url.absoluteString)
        let script = """
        (async () => {
          try {
            const response = await fetch(\(assetURLLiteral), {
              credentials: 'include',
              cache: 'no-store'
            });
            const contentType = response.headers.get('content-type') || '';
            if (!response.ok) {
              return {
                status: response.status,
                contentType,
                bodyBase64: ''
              };
            }

            const blob = await response.blob();
            const bodyBase64 = await new Promise((resolve, reject) => {
              const reader = new FileReader();
              reader.onloadend = () => {
                const result = String(reader.result || '');
                const commaIndex = result.indexOf(',');
                resolve(commaIndex >= 0 ? result.slice(commaIndex + 1) : result);
              };
              reader.onerror = () => reject(new Error('FileReader failed'));
              reader.readAsDataURL(blob);
            });

            return {
              status: response.status,
              contentType,
              bodyBase64
            };
          } catch (error) {
            return {
              error: String(error && error.message ? error.message : error)
            };
          }
        })()
        """

        let payload = try await evaluateJSON(in: webView, script: script)
        let status = payload["status"] as? Int ?? (payload["status"] as? NSNumber)?.intValue ?? 0
        guard (200..<400).contains(status) else {
            throw RenderedPageCrawlerError.stepFailed("asset fetch", "HTTP \(status == 0 ? 403 : status) for \(url.absoluteString)")
        }

        let bodyBase64 = payload["bodyBase64"] as? String ?? ""
        guard let data = Data(base64Encoded: bodyBase64), !data.isEmpty else {
            throw RenderedPageCrawlerError.stepFailed("asset fetch", "Invalid base64 payload")
        }

        return RenderedAssetResponse(
            data: data,
            mimeType: payload["contentType"] as? String
        )
    }

    func fetchImageAssetViaDOM(url: URL, refererPageURL: URL?) async throws -> RenderedAssetResponse {
        let webView = try prepareWebView()
        if let refererPageURL {
            try await load(url: refererPageURL, in: webView)
            try await settlePage(in: webView)
        }

        let assetURLLiteral = Self.javascriptStringLiteral(url.absoluteString)
        let requestedMimeType = preferredCanvasMimeType(for: url)
        let mimeTypeLiteral = Self.javascriptStringLiteral(requestedMimeType)

        let script = """
        (async () => {
          try {
            const assetURL = \(assetURLLiteral);
            const outputMimeType = \(mimeTypeLiteral);
            const result = await new Promise((resolve) => {
              const image = new Image();
              image.crossOrigin = 'anonymous';
              image.decoding = 'sync';

              const finish = (payload) => {
                if (image.parentNode) image.parentNode.removeChild(image);
                resolve(payload);
              };

              const timer = window.setTimeout(() => {
                finish({ error: 'Timed out while loading image resource' });
              }, 30000);

              image.onload = () => {
                try {
                  window.clearTimeout(timer);
                  const width = image.naturalWidth || 0;
                  const height = image.naturalHeight || 0;
                  if (!width || !height) {
                    finish({ error: 'Loaded image has no dimensions' });
                    return;
                  }

                  const canvas = document.createElement('canvas');
                  canvas.width = width;
                  canvas.height = height;
                  const context = canvas.getContext('2d');
                  if (!context) {
                    finish({ error: 'Canvas context unavailable' });
                    return;
                  }

                  context.drawImage(image, 0, 0);
                  const dataURL = outputMimeType === 'image/jpeg'
                    ? canvas.toDataURL(outputMimeType, 0.98)
                    : canvas.toDataURL(outputMimeType);
                  const commaIndex = dataURL.indexOf(',');
                  finish({
                    mimeType: dataURL.slice(5, commaIndex).replace(/;base64$/i, ''),
                    bodyBase64: commaIndex >= 0 ? dataURL.slice(commaIndex + 1) : '',
                    width,
                    height
                  });
                } catch (error) {
                  finish({ error: String(error && error.message ? error.message : error) });
                }
              };

              image.onerror = () => {
                window.clearTimeout(timer);
                finish({ error: 'Image resource failed to load' });
              };

              image.style.position = 'fixed';
              image.style.left = '-20000px';
              image.style.top = '-20000px';
              document.body.appendChild(image);
              image.src = assetURL;
            });

            return result;
          } catch (error) {
            return {
              error: String(error && error.message ? error.message : error)
            };
          }
        })()
        """

        let payload = try await evaluateJSON(in: webView, script: script)
        if let errorMessage = payload["error"] as? String, !errorMessage.isEmpty {
            throw RenderedPageCrawlerError.stepFailed("image resource load", errorMessage)
        }

        let bodyBase64 = payload["bodyBase64"] as? String ?? ""
        guard let data = Data(base64Encoded: bodyBase64), !data.isEmpty else {
            throw RenderedPageCrawlerError.stepFailed("image resource load", "Empty image payload")
        }

        return RenderedAssetResponse(
            data: data,
            mimeType: payload["mimeType"] as? String
        )
    }

    private func prepareWebView() throws -> WKWebView {
        if let webView {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: configuration)
        webView.navigationDelegate = self

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewportSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.contentView = webView
        window.orderFront(nil)
        window.orderOut(nil)

        self.webView = webView
        self.hostWindow = window
        return webView
    }

    private func load(url: URL, in webView: WKWebView) async throws {
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(request)
        }
    }

    private func settlePage(in webView: WKWebView) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(900))

        for _ in 0..<8 {
            try Task.checkCancellation()
            let readyState = try await evaluateString(in: webView, script: "document.readyState")
            if readyState == "complete" {
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        try await Task.sleep(for: .milliseconds(500))
    }

    private func autoScroll(in webView: WKWebView) async throws {
        let scrollMetrics = try await evaluateJSON(in: webView, script: Self.scrollMetricsScript)
        let totalHeight = max((scrollMetrics["height"] as? Double) ?? 0, 0)
        let viewportHeight = max((scrollMetrics["viewport"] as? Double) ?? 0, 0)
        guard totalHeight > 0, viewportHeight > 0 else { return }

        let step = max(viewportHeight * 0.75, 600)
        let maxSteps = 18
        var position = 0.0
        var steps = 0

        while position + viewportHeight < totalHeight, steps < maxSteps {
            try Task.checkCancellation()
            position = min(position + step, totalHeight - viewportHeight)
            _ = try await evaluateJSON(
                in: webView,
                script: "window.scrollTo({ top: \(Int(position)), behavior: 'instant' }); ({ done: true })"
            )
            try await Task.sleep(for: .milliseconds(350))
            steps += 1
        }

        _ = try await evaluateJSON(
            in: webView,
            script: "window.scrollTo({ top: 0, behavior: 'instant' }); ({ done: true })"
        )
        try await Task.sleep(for: .milliseconds(250))
    }

    private func activateVideoContent(in webView: WKWebView) async throws {
        _ = try await evaluateJSON(in: webView, script: Self.videoActivationScript)
        try await Task.sleep(for: .milliseconds(900))
    }

    private func evaluateString(in webView: WKWebView, script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: result as? String ?? "")
            }
        }
    }

    private func evaluateJSON(in webView: WKWebView, script: String) async throws -> [String: Any] {
        let jsonScript = "JSON.stringify(\(script))"
        let jsonString = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(jsonScript) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: result as? String ?? "{}")
            }
        }

        let data = Data(jsonString.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let payload = object as? [String: Any] ?? [:]
        if let message = payload["error"] as? String, !message.isEmpty {
            throw RenderedPageCrawlerError.stepFailed("page script", message)
        }
        return payload
    }

    private static let scrollMetricsScript = """
    (() => {
      const root = document.scrollingElement || document.documentElement || document.body;
      return {
        height: root ? Math.max(root.scrollHeight, document.body ? document.body.scrollHeight : 0) : 0,
        viewport: window.innerHeight || 0
      };
    })();
    """

    private static let htmlSnapshotScript = """
    (() => document.documentElement ? document.documentElement.outerHTML : '')()
    """

    private static let assetAndLinkSnapshotScript = """
    (() => {
      try {
        const absolute = (value) => {
          try { return new URL(value, document.baseURI).href; } catch { return null; }
        };

        const assets = new Set();
        const links = new Set();

        const addAsset = (value) => {
          if (!value || typeof value !== 'string') return;
          const trimmed = value.trim();
          if (!trimmed) return;
          const resolved = absolute(trimmed);
          if (resolved) assets.add(resolved);
        };

        const addSrcset = (value) => {
          if (!value || typeof value !== 'string') return;
          for (const part of value.split(',')) {
            const candidate = part.trim().split(/\\s+/)[0];
            addAsset(candidate);
          }
        };

        document.querySelectorAll('img, source, video, [poster], [style]').forEach((node) => {
          try {
            if (node.currentSrc) addAsset(node.currentSrc);
            if (node.src) addAsset(node.src);
            if (node.getAttribute) {
              addAsset(node.getAttribute('src'));
              addAsset(node.getAttribute('data-src'));
              addAsset(node.getAttribute('data-lazy-src'));
              addAsset(node.getAttribute('data-original'));
              addAsset(node.getAttribute('poster'));
              addSrcset(node.getAttribute('srcset'));
              addSrcset(node.getAttribute('data-srcset'));
            }
          } catch {}
        });

        document.querySelectorAll('iframe[src], iframe[data-src]').forEach((node) => {
          try {
            if (node.getAttribute) {
              addAsset(node.getAttribute('src'));
              addAsset(node.getAttribute('data-src'));
            }
          } catch {}
        });

        const backgroundRegex = /url\\(["']?([^"'\\)]+)["']?\\)/g;
        document.querySelectorAll('*').forEach((node) => {
          try {
            const style = window.getComputedStyle(node);
            const background = style ? style.backgroundImage : '';
            if (background && background !== 'none') {
              let match;
              backgroundRegex.lastIndex = 0;
              while ((match = backgroundRegex.exec(background)) !== null) {
                addAsset(match[1]);
              }
            }
          } catch {}
        });

        document.querySelectorAll('a[href]').forEach((node) => {
          try {
            const href = node.getAttribute('href');
            const resolved = absolute(href);
            if (resolved) links.add(resolved);
          } catch {}
        });

        return {
          assets: Array.from(assets),
          links: Array.from(links)
        };
      } catch (error) {
        return {
          assets: [],
          links: [],
          error: String(error && error.message ? error.message : error)
        };
      }
    })();
    """

    private static let videoActivationScript = """
    (() => {
      try {
        const clicked = [];
        const textMatches = ['watch video', 'play video', 'play reel', 'watch reel', 'play', 'video'];
        const selector = 'button, [role="button"], a, .w-inline-block, .w-button';

        const isVisible = (node) => {
          if (!node || !node.getBoundingClientRect) return false;
          const rect = node.getBoundingClientRect();
          const style = window.getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
        };

        document.querySelectorAll(selector).forEach((node) => {
          try {
            if (!isVisible(node)) return;
            const text = String(node.innerText || (node.getAttribute && node.getAttribute('aria-label')) || '').trim().toLowerCase();
            if (!text) return;
            if (textMatches.some((candidate) => text.includes(candidate))) {
              node.click();
              clicked.push(text.slice(0, 80));
            }
          } catch {}
        });

        document.querySelectorAll('video').forEach((video) => {
          try {
            video.muted = true;
            video.setAttribute('muted', '');
            video.setAttribute('playsinline', '');
            const playResult = video.play && video.play();
            if (playResult && typeof playResult.catch === 'function') {
              playResult.catch(() => {});
            }
          } catch {}
        });

        return { clicked };
      } catch (error) {
        return { clicked: [], error: String(error && error.message ? error.message : error) };
      }
    })();
    """

    private static func javascriptStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    private func preferredCanvasMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "image/png"
        }
    }
}

extension RenderedPageCrawler: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navigationContinuation?.resume(returning: ())
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume(throwing: error)
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume(throwing: error)
            navigationContinuation = nil
        }
    }
}
