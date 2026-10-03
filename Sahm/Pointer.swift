import CryptoKit
import Foundation

enum LinkError: Error {
    case network(Int)
    case format
    case key
    case badURL
    case offline
}

/// Encrypted pointer to the platform's current address (a new Cloudflare quick-tunnel host on every PC start).
/// Same scheme as app/applink.py on the PC: key = HKDF-SHA256(pair key, salt "sahm", info "pointer-v1"),
/// AES-256-GCM with AAD "sahm-pointer-v1"; p.json = {"v": 1, "n": base64(nonce), "c": base64(ciphertext || tag)}.
enum Pointer {
    static let space = "fdgwse5/sahm-app"
    private static let aad = Data("sahm-pointer-v1".utf8)

    static func key(_ pairKey: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(pairKey.utf8)),
                               salt: Data("sahm".utf8), info: Data("pointer-v1".utf8),
                               outputByteCount: 32)
    }

    /// Decrypts one p.json document. LinkError.key = this pair key does not open it.
    static func open(_ json: Data, pairKey: String) throws -> URL {
        guard let doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let n = doc["n"] as? String, let c = doc["c"] as? String,
              let nonce = Data(base64Encoded: n), let sealed = Data(base64Encoded: c), sealed.count > 16
        else { throw LinkError.format }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: sealed.prefix(sealed.count - 16),
                                        tag: sealed.suffix(16))
        } catch {
            throw LinkError.format
        }
        let plain: Data
        do {
            plain = try AES.GCM.open(box, using: key(pairKey), authenticating: aad)
        } catch {
            throw LinkError.key
        }
        guard let body = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let text = body["url"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host != nil
        else { throw LinkError.badURL }
        return url
    }

    /// Newest commit of the Space first (never a cached "main"), then the file at that commit.
    static func fetch(pairKey: String, file: String = "p.json") async throws -> URL {
        let meta = try await get(URL(string: "https://huggingface.co/api/spaces/\(space)")!)
        guard let info = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let sha = info["sha"] as? String else { throw LinkError.format }
        let doc = try await get(URL(string: "https://huggingface.co/spaces/\(space)/resolve/\(sha)/\(file)")!)
        return try open(doc, pairKey: pairKey)
    }

    static func get(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LinkError.network(code) }
        return data
    }

    /// The platform answers /api/health without a key.
    static func healthy(_ base: URL) async -> Bool {
        let url = base.appendingPathComponent("api").appendingPathComponent("health")
        return (try? await get(url, timeout: 8)) != nil
    }

    /// The server at `base` holds the same pairing key: GET /api/health?n=<nonce> must answer
    /// proof = hex(HMAC-SHA256(key, "sahm-health:" + nonce)). Guards remembered or hinted addresses
    /// (which did not come from the encrypted pointer) before the key is sent to them.
    static func proves(_ base: URL, key pairKey: String) async -> Bool {
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let health = base.appendingPathComponent("api").appendingPathComponent("health")
        guard var parts = URLComponents(url: health, resolvingAgainstBaseURL: false) else { return false }
        parts.queryItems = [URLQueryItem(name: "n", value: nonce)]
        guard let url = parts.url, let data = try? await get(url, timeout: 8),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proof = doc["proof"] as? String else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("sahm-health:\(nonce)".utf8),
                                                  using: SymmetricKey(data: Data(pairKey.utf8)))
        return proof == Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}
