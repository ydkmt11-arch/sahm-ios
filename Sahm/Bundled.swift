import CryptoKit
import Foundation

enum PairKey {
    static func isValid(_ key: String) -> Bool {
        (16...128).contains(key.count) && key.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }
    }
}

/// The owner's personal IPA carries pair.json (added by the PC when it serves the download), so the app opens
/// the platform right after installing, with no pairing step: {"v": 1, "k": "<key>", "u": "<address hint>"}.
enum Bundled {
    struct Pair {
        let key: String
        let hint: URL?
    }

    static func read() -> Pair? {
        guard let url = Bundle.main.url(forResource: "pair", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = doc["k"] as? String, PairKey.isValid(key) else { return nil }
        var hint: URL?
        if let text = doc["u"] as? String, let parsed = URL(string: text), parsed.scheme == "https", parsed.host != nil {
            hint = parsed
        }
        return Pair(key: key, hint: hint)
    }

    /// Applies the bundled key once per distinct key (a fresh install, or an update that carries a new key),
    /// so a key pasted later by hand is not overwritten on every launch.
    @discardableResult
    static func applyIfNew() -> Pair? {
        guard let pair = read() else { return nil }
        let digest = SHA256.hash(data: Data(pair.key.utf8)).map { String(format: "%02x", $0) }.joined()
        let mark = "sahm.bundledKeyApplied"
        if UserDefaults.standard.string(forKey: mark) != digest {
            KeyStore.save(pair.key)
            UserDefaults.standard.set(digest, forKey: mark)
        }
        return pair
    }
}
