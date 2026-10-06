import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// The owner's SAHM notifications as iPhone notifications (owner 2026-10-06: «ابي الاشعارات بالبرنامج ال ipa»).
///
/// A free Apple ID cannot sign remote push (APNs needs a paid developer account), so the app fetches the server's
/// feed itself — GET /api/notify/feed?since=<last id> — every minute while it is open, and whenever iOS wakes it in
/// the background (Background App Refresh: iOS decides when, usually 15 minutes or more apart, and never after the
/// app was swiped away until it is opened again). New items become local notifications with the app's own name and
/// icon. Off until the owner taps «تفعيل» in the page (SahmApp.notifyEnable), so nothing ever prompts by itself.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshTask = "io.github.ydkmt11arch.sahm.refresh"

    private let enabledKey = "sahm.notify.enabled"
    private let lastIdKey = "sahm.notify.lastId"
    private let unreadKey = "sahm.notify.unread"
    private let lastURLKey = "sahm.lastURL"           // written by MainViewController after a verified connection
    private var timer: Timer?
    private var fetching = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// Set by the controller: the page learns the state through the event «sahm:notify».
    var onState: (([String: Any]) -> Void)?

    var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: - Launch and life cycle

    /// From application(_:didFinishLaunchingWithOptions:): iOS wants background handlers registered before launch ends.
    func registerAtLaunch() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.refreshTask, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Notifier.shared.runBackground(refresh)
        }
    }

    /// The app is in front: clear the badge, fetch now and every 60 s.
    func foreground() {
        clearBadge()
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Notifier.shared.fetch(background: false) }
        }
        Task { @MainActor in await self.fetch(background: false) }
    }

    /// The app left the screen: stop the timer and ask iOS for the next background wake-up.
    func background() {
        timer?.invalidate()
        timer = nil
        schedule()
    }

    private func schedule() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Notifier.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)       // the simulator refuses: nothing to do about it
    }

    private func runBackground(_ task: BGAppRefreshTask) {
        schedule()                                        // the next wake-up first: one failed fetch never ends the chain
        let work = Task { @MainActor in
            let ok = await Notifier.shared.fetch(background: true)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Owner's switch (from the page)

    func setEnabled(_ on: Bool) {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            timer?.invalidate()
            timer = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Notifier.refreshTask)
            report()
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(granted, forKey: self.enabledKey)
                if granted {
                    UserDefaults.standard.removeObject(forKey: self.lastIdKey)   // first sync = from now, no history
                    self.foreground()
                    self.schedule()
                }
                self.report()
            }
        }
    }

    /// Tell the page: permission, the owner's switch, and whether iOS allows background refresh.
    func report() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized: status = "authorized"
            case .denied: status = "denied"
            case .provisional: status = "provisional"
            case .ephemeral: status = "ephemeral"
            default: status = "notDetermined"
            }
            DispatchQueue.main.async {
                let bg: String
                switch UIApplication.shared.backgroundRefreshStatus {
                case .available: bg = "available"
                case .denied: bg = "denied"
                case .restricted: bg = "restricted"
                @unknown default: bg = "unknown"
                }
                self.onState?(["status": status, "enabled": self.enabled, "bg": bg])
            }
        }
    }

    // MARK: - Fetch and show

    /// The live address: the controller's, else the last verified one (a background launch has no controller).
    private func currentBase() -> URL? {
        if let base = Link.shared.base { return base }
        guard let text = UserDefaults.standard.string(forKey: lastURLKey) else { return nil }
        return URL(string: text)
    }

    private func request(base: URL, key: String, query: [URLQueryItem], timeout: TimeInterval) -> URLRequest? {
        var comps = URLComponents(url: base.appendingPathComponent("api/notify/feed"), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(key, forHTTPHeaderField: "X-Dash-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// Ask the server what is new and show it. True when the server answered.
    @discardableResult
    @MainActor
    func fetch(background: Bool) async -> Bool {
        guard enabled, !fetching, let key = KeyStore.read() ?? Link.shared.key, let base = currentBase() else { return false }
        fetching = true
        defer { fetching = false }
        let last = UserDefaults.standard.object(forKey: lastIdKey) as? Int
        var query: [URLQueryItem] = []
        if let last = last { query.append(URLQueryItem(name: "since", value: String(last))) }
        if background { query.append(URLQueryItem(name: "bg", value: "1")) }
        guard let req = request(base: base, key: key, query: query, timeout: 20) else { return false }
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lastId = obj["last_id"] as? Int else { return false }
            let items = obj["items"] as? [[String: Any]] ?? []
            let reset = obj["reset"] as? Bool ?? false
            if last != nil && !reset {
                await show(items, more: obj["more"] as? Int ?? 0)
            }
            UserDefaults.standard.set(lastId, forKey: lastIdKey)
            return true
        } catch {
            return false
        }
    }

    /// A long gap shows the newest six and one line for the rest.
    @MainActor
    private func show(_ items: [[String: Any]], more: Int) async {
        let center = UNUserNotificationCenter.current()
        let shown = Array(items.suffix(6))
        let hidden = more + items.count - shown.count
        for item in shown {
            let content = UNMutableNotificationContent()
            content.title = item["title"] as? String ?? "سهم"
            content.body = item["text"] as? String ?? ""
            content.sound = .default
            content.threadIdentifier = item["kind"] as? String ?? "sahm"
            content.badge = NSNumber(value: bumpUnread())
            let id = "sahm-\(item["id"] as? Int ?? Int(Date().timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if hidden > 0 {
            let content = UNMutableNotificationContent()
            content.title = "سهم"
            content.body = "و\(hidden) تنبيهات أخرى — افتح سهم ← لوحة الإدارة ← الإشعارات."
            content.sound = nil
            content.badge = NSNumber(value: bumpUnread())
            try? await center.add(UNNotificationRequest(identifier: "sahm-more-\(Date().timeIntervalSince1970)",
                                                        content: content, trigger: nil))
        }
    }

    private func bumpUnread() -> Int {
        let n = UserDefaults.standard.integer(forKey: unreadKey) + 1
        UserDefaults.standard.set(n, forKey: unreadKey)
        return n
    }

    private func clearBadge() {
        UserDefaults.standard.set(0, forKey: unreadKey)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// In front too: show the banner (a trade happening while the owner reads another screen).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: - CI

    /// CI only: one read of the feed (ci=1: not counted as the owner's phone), nothing shown, nothing stored.
    @MainActor
    func ciFetch() async -> String {
        guard let key = KeyStore.read() ?? Link.shared.key else { return "no-key" }
        guard let base = currentBase() else { return "no-base" }
        guard let req = request(base: base, key: key, query: [URLQueryItem(name: "ci", value: "1")], timeout: 10) else {
            return "bad-url"
        }
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let last = obj?["last_id"] as? Int
            return "\(code):\(last.map { String($0) } ?? "-")"
        } catch {
            return "error:\(error.localizedDescription)"
        }
    }
}
