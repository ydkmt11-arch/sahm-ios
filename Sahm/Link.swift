import Foundation

/// The platform's current address and the pairing key, shared by the controller, the API proxy (AppScheme) and the
/// interface updater (UIUpdater). Thread-safe: the proxy reads it from URLSession's queues.
final class Link {
    static let shared = Link()

    private let lock = NSLock()
    private var currentBase: URL?
    private var currentKey: String?
    private var lastFailure: Date?

    var base: URL? {
        get { lock.lock(); defer { lock.unlock() }; return currentBase }
        set { lock.lock(); currentBase = newValue; lastFailure = nil; lock.unlock() }
    }

    var key: String? {
        get { lock.lock(); defer { lock.unlock() }; return currentKey }
        set { lock.lock(); currentKey = newValue; lock.unlock() }
    }

    /// The proxy could not reach `base`. For a few seconds later requests answer from the phone's copy at once
    /// instead of each waiting for its own timeout.
    func markDown() {
        lock.lock(); lastFailure = Date(); lock.unlock()
    }

    func markUp() {
        lock.lock(); lastFailure = nil; lock.unlock()
    }

    var recentlyDown: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failure = lastFailure else { return false }
        return Date().timeIntervalSince(failure) < 15
    }

    /// Set by the controller; called on the main thread when the proxy cannot reach `base`.
    var onUnreachable: (() -> Void)?
}
