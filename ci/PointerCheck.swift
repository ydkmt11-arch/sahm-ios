import Foundation

/// CI: CryptoKit must open the pointer that the PC (Python, app/applink.py) published, and refuse wrong keys.
@main
struct PointerCheck {
    static func main() async {
        let ciKey = "ci-dummy-key-0000000000"
        let expected = "https://fdgwse5-sahm-app.static.hf.space"
        do {
            let url = try await Pointer.fetch(pairKey: ciKey, file: "p_ci.json")
            guard url.absoluteString == expected else { fail("decrypted \(url.absoluteString), expected \(expected)") }
            print("CI pointer decrypted by CryptoKit: \(url.absoluteString)")
        } catch {
            fail("could not open the CI pointer: \(error)")
        }
        for (key, file) in [(ciKey + "x", "p_ci.json"), (ciKey, "p.json")] {
            do {
                _ = try await Pointer.fetch(pairKey: key, file: file)
                fail("\(file) opened with the wrong key")
            } catch LinkError.key {
                print("wrong key refused for \(file)")
            } catch {
                fail("\(file): unexpected \(error)")
            }
        }
        let alive = await Pointer.healthy(URL(string: expected)!)
        guard alive else { fail("health check of \(expected) failed") }
        print("pointer check OK")
    }

    static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }
}
