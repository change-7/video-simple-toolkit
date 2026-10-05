import SwiftUI
import WebKit

struct WebVideoDiscoveryRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct WebVideoCandidate: Identifiable {
    let url: String
    let refererURL: String
    var status = "확인 중"
    var isAvailable = false

    var id: String { url }

    var kind: String {
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        if path.hasSuffix(".m3u8") { return "HLS" }
        if path.hasSuffix(".mpd") { return "DASH" }
        return "영상"
    }

    static func normalizedURL(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\r"), !value.contains("\n"),
              let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(),
              host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", host != "0.0.0.0",
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else {
            return nil
        }
        return value
    }
}

@MainActor
private final class WebVideoDiscoveryModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var candidates: [WebVideoCandidate] = []
    @Published var pageTitle: String?
    @Published var statusText = "페이지를 여는 중"

    weak var webView: WKWebView?
    private let ffprobeURL: URL?
    private let ffmpegURL: URL?
    private let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var seenURLs = Set<String>()

    init(ffprobeURL: URL?, ffmpegURL: URL?) {
        self.ffprobeURL = ffprobeURL
        self.ffmpegURL = ffmpegURL
    }

    func scan() {
        guard let webView else { return }
        candidates.removeAll()
        seenURLs.removeAll()
        statusText = "재생 중인 영상 주소를 찾는 중"
        webView.evaluateJavaScript("window.postMessage('VST_SCAN_MEDIA', '*')") { [weak self] _, error in
            if error != nil { self?.statusText = "페이지에서 영상 정보를 읽지 못했습니다." }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.candidates.isEmpty,
                  self.statusText == "재생 중인 영상 주소를 찾는 중" else { return }
            self.statusText = "영상 주소를 찾지 못했습니다. 재생한 뒤 다시 시도해 주세요."
        }
    }

    func close() {
        probeQueue.cancelAllOperations()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vstMedia")
        webView = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        candidates.removeAll()
        seenURLs.removeAll()
        statusText = "페이지를 여는 중"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageTitle = webView.title
        statusText = "페이지에서 영상을 재생한 뒤 ‘영상 찾기’를 누르세요."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusText = "페이지를 열지 못했습니다: \(error.localizedDescription)"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let rawURLs = payload["urls"] as? [String],
              let pageURL = payload["pageURL"] as? String,
              let refererURL = WebVideoCandidate.normalizedURL(pageURL)
                ?? webView?.url?.absoluteString else { return }

        for rawURL in rawURLs {
            guard candidates.count < 20,
                  let url = WebVideoCandidate.normalizedURL(rawURL),
                  seenURLs.insert(url).inserted else { continue }
            candidates.append(WebVideoCandidate(url: url, refererURL: refererURL))
            validate(url: url, refererURL: refererURL)
        }
        if !candidates.isEmpty {
            statusText = "발견한 영상 후보 \(candidates.count)개를 확인 중"
        }
    }

    private func validate(url: String, refererURL: String) {
        let ffprobeURL = self.ffprobeURL
        let ffmpegURL = self.ffmpegURL
        probeQueue.addOperation { [weak self] in
            let origin = URLComponents(string: refererURL).flatMap { parts -> String? in
                guard let scheme = parts.scheme, let host = parts.host else { return nil }
                return "\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")"
            }
            var inputOptions = ["-user_agent", "Mozilla/5.0"]
            var headers = "Referer: \(refererURL)\r\n"
            if let origin { headers += "Origin: \(origin)\r\n" }
            inputOptions += ["-headers", headers]

            let valid: Bool
            if let ffprobeURL {
                let result = ProcessRunner.runAndCapture(
                    executableURL: ffprobeURL,
                    arguments: inputOptions + ["-v", "error", "-rw_timeout", "5000000",
                                               "-show_entries", "stream=codec_type", "-of", "csv=p=0", url]
                )
                let kinds = result?.stdout.split(whereSeparator: \.isNewline).map(String.init) ?? []
                valid = result?.terminationStatus == 0 && kinds.contains(where: { ["video", "audio"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            } else if let ffmpegURL {
                let result = ProcessRunner.runAndCapture(
                    executableURL: ffmpegURL,
                    arguments: inputOptions + ["-v", "error", "-rw_timeout", "5000000", "-i", url,
                                               "-t", "0.2", "-f", "null", "-"]
                )
                valid = result?.terminationStatus == 0
            } else {
                valid = false
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, let index = self.candidates.firstIndex(where: { $0.url == url }) else { return }
                self.candidates[index].isAvailable = valid
                self.candidates[index].status = valid ? "재생 가능" : "확인 실패"
                if !self.candidates.contains(where: { $0.status == "확인 중" }) {
                    self.statusText = "확인된 영상 \(self.candidates.filter(\.isAvailable).count)개"
                }
            }
        }
    }
}

private struct WebVideoBrowser: NSViewRepresentable {
    let pageURL: URL
    @ObservedObject var model: WebVideoDiscoveryModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(model, name: "vstMedia")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.discoveryScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = model
        model.webView = webView
        webView.load(URLRequest(url: pageURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    private static let discoveryScript = """
    (() => {
      if (window.__vstMediaScanner) return;
      window.__vstMediaScanner = true;
      window.addEventListener('message', event => {
        if (event.data !== 'VST_SCAN_MEDIA') return;
        const urls = [];
        const add = value => {
          if (!value || value.startsWith('blob:') || value.startsWith('data:')) return;
          if (/^https?:\\/\\//i.test(value)) { urls.push(value); return; }
          try { urls.push(new URL(value, location.href).href); } catch (_) {}
        };
        document.querySelectorAll('video, audio, source').forEach(node => {
          add(node.currentSrc); add(node.src); add(node.getAttribute('data-src'));
        });
        document.querySelectorAll('meta[property="og:video"],meta[property="og:video:url"]').forEach(node => add(node.content));
        performance.getEntriesByType('resource').forEach(entry => {
          if (entry.initiatorType === 'video' || entry.initiatorType === 'audio' ||
              /\\.(m3u8|mpd|mp4|m4a|webm|mov)(?:[?#]|$)|\\/(m3|hls|dash|manifest|playlist|master|stream)(?:[/?#]|$)/i.test(entry.name)) add(entry.name);
        });
        window.webkit.messageHandlers.vstMedia.postMessage({urls: [...new Set(urls)].slice(0, 100), pageURL: location.href});
        document.querySelectorAll('iframe').forEach(frame => {
          try { frame.contentWindow?.postMessage('VST_SCAN_MEDIA', '*'); } catch (_) {}
        });
      });
    })();
    """
}

struct WebVideoDiscoveryView: View {
    let pageURL: URL
    let onDownload: (WebVideoCandidate, String?) -> Bool
    @StateObject private var model: WebVideoDiscoveryModel
    @Environment(\.dismiss) private var dismiss

    init(pageURL: URL, ffprobeURL: URL?, ffmpegURL: URL?, onDownload: @escaping (WebVideoCandidate, String?) -> Bool) {
        self.pageURL = pageURL
        self.onDownload = onDownload
        _model = StateObject(wrappedValue: WebVideoDiscoveryModel(ffprobeURL: ffprobeURL, ffmpegURL: ffmpegURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.pageTitle ?? pageURL.host ?? "웹페이지")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("영상 찾기") { model.scan() }
                Button("닫기") { dismiss() }
            }

            WebVideoBrowser(pageURL: pageURL, model: model)
                .frame(minHeight: 350)

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.candidates) { candidate in
                        HStack(spacing: 8) {
                            Text(candidate.kind)
                                .font(.caption.weight(.semibold))
                                .frame(width: 44, alignment: .leading)
                            Text(candidate.url)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(candidate.status)
                                .font(.caption)
                                .foregroundStyle(candidate.isAvailable ? .green : .secondary)
                            Button("다운로드") {
                                if onDownload(candidate, model.pageTitle) { dismiss() }
                            }
                            .disabled(!candidate.isAvailable)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 600)
        .onDisappear { model.close() }
    }
}
