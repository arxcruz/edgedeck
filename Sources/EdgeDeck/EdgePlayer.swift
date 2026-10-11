import AppKit
import WebKit

/// Finds the URL of the browser tab that is playing, via Accessibility.
/// Works for Chromium browsers (Vivaldi, Chrome, Brave, Edge, Arc) and Safari:
/// each window exposes its active tab as an AXWebArea with an AXURL.
enum BrowserTab {
    static let browsers: Set<String> = [
        "com.vivaldi.Vivaldi", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier.map(browsers.contains) ?? false
    }

    /// The http(s) page whose title matches `title`, or the only page open if just one.
    static func url(in app: NSRunningApplication, matching title: String) -> URL? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium only builds its web-content tree once an assistive client asks for it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var pages: [(title: String, url: URL)] = []
        for window in AX.value(element, kAXWindowsAttribute) as [AXUIElement]? ?? [] {
            collect(window, depth: 0, into: &pages)
        }
        let wanted = normalize(title)
        if let match = pages.first(where: { normalize($0.title).contains(wanted) || wanted.contains(normalize($0.title)) }) {
            return match.url
        }
        return pages.count == 1 ? pages[0].url : nil
    }

    private static func collect(_ element: AXUIElement, depth: Int, into pages: inout [(title: String, url: URL)]) {
        guard depth < 40 else { return }
        if (AX.value(element, kAXRoleAttribute) as String?) == "AXWebArea",
           let url: URL = AX.value(element, "AXURL"), ["http", "https"].contains(url.scheme) {
            pages.append((AX.value(element, kAXTitleAttribute) ?? "", url))
            return
        }
        for child in AX.children(element) { collect(child, depth: depth + 1, into: &pages) }
    }

    private static func normalize(_ text: String) -> String {
        // Tab titles carry extras like "(81) " unread counts and " - YouTube".
        text.lowercased().replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " - youtube", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Plays a browser video full-size on the Edge in a WebKit view, so it can be
/// watched there while the browser stays on the main display.
final class EdgePlayer: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var isOpen = false
    @Published private(set) var title = ""
    @Published private(set) var source: NSRunningApplication?

    private var window: PlayerWindow?
    private var webView: WKWebView?
    private var pageURL: URL?
    private var startAt: Double = 0
    private var usingEmbed = false

    // Safari's UA, so sites serve their normal desktop player to the web view.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func open(_ url: URL, at seconds: Double, title: String, source: NSRunningApplication?, frame: NSRect) {
        close()
        self.title = title
        self.source = source
        pageURL = url
        startAt = max(0, seconds)

        let window = PlayerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        self.window = window

        if let id = Self.youTubeID(url) {
            loadEmbed(id)
        } else {
            loadPage(url)
        }
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        isOpen = true
    }

    /// Current playback position in the player, or nil if unknown.
    func currentTime(_ completion: @escaping (Double?) -> Void) {
        guard let webView else { return completion(nil) }
        webView.evaluateJavaScript("window.edgedeckCurrentTime ? edgedeckCurrentTime() : -1") { result, _ in
            let time = (result as? Double) ?? (result as? NSNumber)?.doubleValue ?? -1
            completion(time >= 0 ? time : nil)
        }
    }

    /// Debug aid for EDGEDECK_SNAPSHOT: renders the player's page to a PNG.
    func snapshot(to path: String) {
        webView?.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func togglePlay() {
        webView?.evaluateJavaScript("window.edgedeckToggle && edgedeckToggle()")
    }

    func close() {
        guard isOpen || window != nil else { return }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "edgedeck")
        webView?.pauseAllMediaPlayback()
        webView?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
        isOpen = false
    }

    // MARK: Loading

    private func makeWebView(userScript: String?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(self, name: "edgedeck")
        if let userScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: userScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window?.contentView = webView
        self.webView = webView
        return webView
    }

    /// YouTube's IFrame player: a clean full-window player with touch controls.
    /// It's hosted on a page with an origin so YouTube accepts the embed.
    private func loadEmbed(_ id: String) {
        usingEmbed = true
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:fixed;inset:0;width:100%;height:100%}</style>
            </head><body><div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
            var player;
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                width: '100%', height: '100%', videoId: '\(id)',
                playerVars: { autoplay: 1, start: \(Int(startAt)), playsinline: 1, rel: 0, origin: 'https://edgedeck.app' },
                events: {
                  onReady: function (e) { e.target.playVideo(); },
                  onError: function (e) { window.webkit.messageHandlers.edgedeck.postMessage({ embedError: e.data }); }
                }
              });
            }
            window.edgedeckCurrentTime = function () { return player && player.getCurrentTime ? player.getCurrentTime() : -1; };
            window.edgedeckToggle = function () {
              if (!player || !player.getPlayerState) return;
              player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo();
            };
            </script></body></html>
            """
        makeWebView(userScript: nil).loadHTMLString(html, baseURL: URL(string: "https://edgedeck.app/"))
    }

    /// Any other page: load it and stretch its largest <video> over the whole view.
    private func loadPage(_ url: URL) {
        usingEmbed = false
        let script = """
            (function () {
              if (window.__edgedeck) return; window.__edgedeck = true;
              var start = \(startAt), seeked = start <= 0;
              var style = document.createElement('style');
              style.textContent = 'video[data-edgedeck]{position:fixed!important;inset:0!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important;transform:none!important}html,body{overflow:hidden!important}';
              function biggest() {
                var videos = Array.from(document.querySelectorAll('video'));
                videos.sort(function (a, b) { return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight; });
                return videos[0];
              }
              function apply() {
                var v = biggest(); if (!v) return;
                document.querySelectorAll('video[data-edgedeck]').forEach(function (o) { if (o !== v) o.removeAttribute('data-edgedeck'); });
                v.setAttribute('data-edgedeck', '');
                if (!style.isConnected) document.documentElement.appendChild(style);
                if (!seeked && v.readyState > 0) { v.currentTime = start; seeked = true; }
                if (v.paused && !v.__edgedeckUserPaused) v.play().catch(function () {});
              }
              setInterval(apply, 1000); apply();
              window.edgedeckCurrentTime = function () { var v = biggest(); return v ? v.currentTime : -1; };
              window.edgedeckToggle = function () {
                var v = biggest(); if (!v) return;
                if (v.paused) { v.__edgedeckUserPaused = false; v.play(); } else { v.__edgedeckUserPaused = true; v.pause(); }
              };
            })();
            """
        makeWebView(userScript: script).load(URLRequest(url: Self.withStartTime(url, startAt)))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Some videos forbid embedding (errors 101/150/153); fall back to the full page.
        guard let body = message.body as? [String: Any], body["embedError"] != nil, usingEmbed, let pageURL else { return }
        NSLog("EdgeDeck: YouTube embed refused (\(body["embedError"] ?? "")), loading the page instead")
        loadPage(pageURL)
    }

    // MARK: URLs

    static func youTubeID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") { return url.pathComponents.dropFirst().first }
        guard host.hasSuffix("youtube.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), index + 1 < parts.count {
            return parts[index + 1]
        }
        return nil
    }

    private static func withStartTime(_ url: URL, _ seconds: Double) -> URL {
        guard seconds > 1, url.host?.contains("youtube") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "t" } + [URLQueryItem(name: "t", value: "\(Int(seconds))s")]
        return components.url ?? url
    }
}
