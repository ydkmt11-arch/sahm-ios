import CryptoKit
import Foundation

enum Hex {
    static func of<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        of(SHA256.hash(data: data))
    }
}

/// Manifest of one copy of the interface. Same format as ios/app/ci/personalize.py on the PC:
/// lines = "<path> <sha256> <size>" per file; version = sha256(lines); sig = HMAC-SHA256(key, version\nbuilt_at\nlines).
struct UIManifest {
    struct File {
        let path: String
        let hash: String
        let size: Int
    }

    let version: String
    let builtAt: String
    let files: [File]
    let sig: String

    init?(data: Data) {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = doc["version"] as? String, version.count >= 8,
              let builtAt = doc["built_at"] as? String,
              let list = doc["files"] as? [[String: Any]], !list.isEmpty else { return nil }
        var files: [File] = []
        for item in list {
            guard let path = item["p"] as? String, let hash = item["h"] as? String,
                  let size = (item["n"] as? NSNumber)?.intValue, UIManifest.isSafe(path) else { return nil }
            files.append(File(path: path, hash: hash.lowercased(), size: size))
        }
        guard files.contains(where: { $0.path == "index.html" }) else { return nil }
        self.version = version
        self.builtAt = builtAt
        self.files = files
        self.sig = ((doc["sig"] as? String) ?? "").lowercased()
    }

    /// Relative path made of [A-Za-z0-9._/-], no "..", no leading or double slash.
    static func isSafe(_ path: String) -> Bool {
        if path.isEmpty || path.count >= 200 || path.hasPrefix("/") || path.contains("..") || path.contains("//") {
            return false
        }
        for scalar in path.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || scalar == "." || scalar == "_" || scalar == "/" || scalar == "-"
            if !ok { return false }
        }
        return true
    }

    var lines: String {
        files.map { "\($0.path) \($0.hash) \($0.size)" }.joined(separator: "\n")
    }

    /// Signed by the PC with the pairing key, and the version is the hash of the file list.
    func verify(key: String) -> Bool {
        let canonical = version + "\n" + builtAt + "\n" + lines
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return sig == Hex.of(mac) && version == Hex.sha256(Data(lines.utf8))
    }

    var json: Data {
        var list: [[String: Any]] = []
        for file in files {
            let entry: [String: Any] = ["p": file.path, "h": file.hash, "n": file.size]
            list.append(entry)
        }
        let doc: [String: Any] = ["v": 1, "version": version, "built_at": builtAt, "sig": sig, "files": list]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }
}

/// Copies of the interface on the phone: the one built into this IPA (Sahm.app/www, added by the PC to the owner's
/// download) and the ones downloaded later (Application Support/ui/<version>). The newest built_at wins; a copy that
/// failed to start is never chosen again.
enum WebBundle {
    struct Root {
        let dir: URL
        let manifest: UIManifest
        let builtIn: Bool
    }

    static var store: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ui", isDirectory: true)
    }

    static func load(_ dir: URL, builtIn: Bool) -> Root? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = UIManifest(data: data),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else { return nil }
        return Root(dir: dir, manifest: manifest, builtIn: builtIn)
    }

    static var builtIn: Root? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return load(resources.appendingPathComponent("www", isDirectory: true), builtIn: true)
    }

    static var downloaded: [Root] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.filter { !$0.lastPathComponent.hasPrefix("tmp-") }.compactMap { load($0, builtIn: false) }
    }

    private static let badKey = "sahm.ui.bad"

    static var bad: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: badKey) ?? [])
    }

    static func markBad(_ version: String) {
        var all = bad
        all.insert(version)
        UserDefaults.standard.set(Array(all), forKey: badKey)
    }

    static func best(excluding: Set<String> = []) -> Root? {
        let skip = bad.union(excluding)
        var all = downloaded
        if let own = builtIn { all.append(own) }
        let usable = all.filter { !skip.contains($0.manifest.version) }
        return usable.max { a, b in
            if a.manifest.builtAt != b.manifest.builtAt { return a.manifest.builtAt < b.manifest.builtAt }
            return a.builtIn && !b.builtIn
        }
    }
}

/// Brings newer copies of the interface from the PC: GET /api/ui/manifest (signed), then only the files whose hash
/// is not already on the phone, each checked before the copy is used. Never touches the copy on screen.
final class UIUpdater {
    static let shared = UIUpdater()

    enum Outcome {
        case installed(WebBundle.Root)
        case upToDate
        case failed(String)
        case skipped
    }

    private var running = false
    private var lastCheck = Date.distantPast

    @MainActor
    func check(current: String?, force: Bool) async -> Outcome {
        guard !running, let base = Link.shared.base, let key = Link.shared.key else { return .skipped }
        if !force && Date().timeIntervalSince(lastCheck) < 600 { return .skipped }
        running = true
        defer { running = false }
        lastCheck = Date()
        do {
            let data = try await UIUpdater.get(base, "api/ui/manifest", key: key, timeout: 20)
            guard let manifest = UIManifest(data: data) else { return .failed("format") }
            guard manifest.verify(key: key) else { return .failed("signature") }
            if manifest.version == current || WebBundle.bad.contains(manifest.version) { return .upToDate }
            if let have = WebBundle.downloaded.first(where: { $0.manifest.version == manifest.version }) {
                return .installed(have)
            }
            return .installed(try await install(manifest, base: base, key: key, keep: current))
        } catch {
            return .failed(String(describing: error))
        }
    }

    @MainActor
    private func install(_ manifest: UIManifest, base: URL, key: String, keep: String?) async throws -> WebBundle.Root {
        let fm = FileManager.default
        try fm.createDirectory(at: WebBundle.store, withIntermediateDirectories: true)
        let tmp = WebBundle.store.appendingPathComponent("tmp-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var have: [String: URL] = [:]                    // files already on the phone, by hash
        var roots = WebBundle.downloaded
        if let own = WebBundle.builtIn { roots.append(own) }
        for root in roots {
            for file in root.manifest.files {
                have[file.hash] = root.dir.appendingPathComponent(file.path)
            }
        }

        var missing: [UIManifest.File] = []
        for file in manifest.files {
            let dest = tmp.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let source = have[file.hash], let data = try? Data(contentsOf: source), Hex.sha256(data) == file.hash {
                try data.write(to: dest)
            } else {
                missing.append(file)
            }
        }

        var index = 0
        while index < missing.count {                    // six downloads at a time
            let batch = Array(missing[index..<min(index + 6, missing.count)])
            index += batch.count
            try await withThrowingTaskGroup(of: (UIManifest.File, Data).self) { group in
                for file in batch {
                    group.addTask {
                        let data = try await UIUpdater.get(base, "api/ui/f/" + file.path, key: key, timeout: 60)
                        return (file, data)
                    }
                }
                for try await pair in group {
                    let file = pair.0
                    let data = pair.1
                    guard data.count == file.size, Hex.sha256(data) == file.hash else { throw LinkError.format }
                    try data.write(to: tmp.appendingPathComponent(file.path))
                }
            }
        }

        try manifest.json.write(to: tmp.appendingPathComponent("manifest.json"))   // last: a folder without it is unused
        let final = WebBundle.store.appendingPathComponent(manifest.version, isDirectory: true)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
        for root in WebBundle.downloaded where root.manifest.version != manifest.version && root.manifest.version != keep {
            try? fm.removeItem(at: root.dir)
        }
        guard let root = WebBundle.load(final, builtIn: false) else { throw LinkError.format }
        return root
    }

    static func get(_ base: URL, _ path: String, key: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.setValue(key, forHTTPHeaderField: "X-Dash-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LinkError.network(code) }
        return data
    }
}
