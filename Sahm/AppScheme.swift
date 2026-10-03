import Foundation
import WebKit

/// sahmui://app/… — the interface's files come from the copy on the phone; /api/* is forwarded to the PC with the
/// pairing key added here (the key never enters the page). Every good GET answer is kept, so when the PC is off the
/// page still shows the last data, marked with the header X-Sahm-Offline: <unix time of that copy>.
final class AppScheme: NSObject, WKURLSchemeHandler {
    static let name = "sahmui"
    static let home = URL(string: "sahmui://app/")!

    /// Folder of the interface copy on screen. Main thread only.
    var root: URL?
    /// CI only (-ciForceOffline YES): behave as if the PC were off.
    var forceOffline = false

    private var live = Set<ObjectIdentifier>()           // started and not stopped; main thread only
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        live.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        guard let url = urlSchemeTask.request.url else {
            reply(urlSchemeTask, status: 400, type: "text/plain", body: Data())
            return
        }
        let path = url.path.isEmpty ? "/" : url.path
        if path.hasPrefix("/api/") {
            forward(urlSchemeTask, url: url)
        } else {
            serveFile(urlSchemeTask, path: path)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    // MARK: - Files

    private func serveFile(_ task: WKURLSchemeTask, path: String) {
        var rel = String(path.dropFirst())
        if rel.isEmpty { rel = "index.html" }
        guard let root = root, UIManifest.isSafe(rel),
              var data = try? Data(contentsOf: root.appendingPathComponent(rel)) else {
            reply(task, status: 404, type: "text/plain; charset=utf-8", body: Data("not found".utf8))
            return
        }
        if rel == "index.html" { data = AppScheme.withoutTelegram(data) }
        reply(task, status: 200, type: AppScheme.mime(rel), body: data)
    }

    /// Inside the app there is no Telegram: drop its script (an outside request that would also fail offline).
    static func withoutTelegram(_ data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8) else { return data }
        let tag = "<script src=\"https://telegram.org/js/telegram-web-app.js\"></script>"
        return Data(html.replacingOccurrences(of: tag, with: "").utf8)
    }

    static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - API proxy

    private func forward(_ task: WKURLSchemeTask, url: URL) {
        let request = task.request
        let method = (request.httpMethod ?? "GET").uppercased()
        let cacheKey: String? = method == "GET" ? Hex.sha256(Data(url.absoluteString.utf8)) : nil
        guard !forceOffline, !Link.shared.recentlyDown, let base = Link.shared.base, let key = Link.shared.key,
              var target = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            answerOffline(task, cacheKey: cacheKey)
            return
        }
        target.percentEncodedPath = source.percentEncodedPath
        target.percentEncodedQuery = source.percentEncodedQuery
        guard let targetURL = target.url else {
            answerOffline(task, cacheKey: cacheKey)
            return
        }
        let path = source.percentEncodedPath
        let slow = path.hasPrefix("/api/chart") || path.hasPrefix("/api/analysis") || path.hasPrefix("/api/lab")
        var out = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: method == "GET" ? (slow ? 45 : 15) : 40)
        out.httpMethod = method
        if method != "GET" { out.httpBody = AppScheme.body(of: request) }
        if let type = request.value(forHTTPHeaderField: "Content-Type") {
            out.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        out.setValue("application/json", forHTTPHeaderField: "Accept")
        out.setValue(key, forHTTPHeaderField: "X-Dash-Key")
        session.dataTask(with: out) { [weak self] data, response, error in
            guard let self = self else { return }
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let tunnelError = [502, 503, 504, 520, 521, 522, 523, 524, 530].contains(http?.statusCode ?? 0)
                && !type.contains("json")                   // Cloudflare's own page: the tunnel or the PC is gone
            guard error == nil, let answer = http, let body = data, !tunnelError else {
                Link.shared.markDown()
                DispatchQueue.main.async { Link.shared.onUnreachable?() }
                self.answerOffline(task, cacheKey: cacheKey)
                return
            }
            Link.shared.markUp()
            if let k = cacheKey, answer.statusCode == 200 { ApiCache.write(k, body) }
            self.reply(task, status: answer.statusCode, type: type.isEmpty ? "application/json" : type, body: body)
        }.resume()
    }

    /// WebKit gives a custom scheme the body of a fetch() as httpBody (or a stream on some versions); the page also
    /// sends it base64 in X-Sahm-Body, so a POST never arrives empty.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            if !data.isEmpty { return data }
        }
        if let encoded = request.value(forHTTPHeaderField: "X-Sahm-Body"), let data = Data(base64Encoded: encoded) {
            return data
        }
        return nil
    }

    private func answerOffline(_ task: WKURLSchemeTask, cacheKey: String?) {
        if let k = cacheKey, let hit = ApiCache.read(k) {
            reply(task, status: 200, type: "application/json", body: hit.data,
                  extra: ["X-Sahm-Offline": String(Int(hit.date.timeIntervalSince1970))])
            return
        }
        let message: [String: Any] = ["detail": "المنصة غير متصلة الآن — تأكد أن سهم يعمل على الكمبيوتر"]
        let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        reply(task, status: 503, type: "application/json", body: body, extra: ["X-Sahm-Offline": "0"])
    }

    private func reply(_ task: WKURLSchemeTask, status: Int, type: String, body: Data, extra: [String: String] = [:]) {
        let send = {
            let id = ObjectIdentifier(task as AnyObject)
            guard self.live.contains(id), let url = task.request.url else { return }
            self.live.remove(id)
            var headers = extra
            headers["Content-Type"] = type
            headers["Content-Length"] = String(body.count)
            headers["Cache-Control"] = "no-store"
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else { return }
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }
        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async(execute: send)
        }
    }
}

/// Last good answer of every GET, kept on the phone for when the PC is off.
enum ApiCache {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("api-cache", isDirectory: true)
    }

    static func write(_ key: String, _ data: Data) {
        guard data.count < 8_000_000 else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(key), options: .atomic)
    }

    static func read(_ key: String) -> (data: Data, date: Date)? {
        let url = dir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (data, date)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
