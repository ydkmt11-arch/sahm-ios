import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// SAHM's notifications as iPhone notifications (owner 2026-10-06: «ابي الاشعارات بالبرنامج ال ipa» and, in v1.4,
/// «أول ما يفتح التطبيق تطلع النافذة الأصلية تطلب الإذن مثل أي تطبيق»).
///
/// HONEST LIMIT, stated in the interface too: this IPA is sideloaded with a FREE Apple ID, and free provisioning
/// cannot carry the `aps-environment` entitlement, so APNs (remote push) is impossible without the paid Apple
/// Developer Program. What this class does instead: it fetches the server's own feed —
/// GET /api/notify/feed?since=<last id>&did=<this install> — every minute while the app is open, and whenever iOS
/// wakes it (Background App Refresh + a Background Processing task). New items become LOCAL notifications with the
/// app's name and icon. In the background iOS alone decides when (usually ≥15 minutes apart, never after the app was
/// swiped away until it is opened again), so background delivery is best effort. Guaranteed-while-closed delivery is
/// Telegram, or Web Push to سهم added to the Home Screen.
///
/// v1.4: the system permission sheet appears by itself on the FIRST launch (like any other app); the switch in the
/// page stays as a fallback, and each install has its own device id so every phone keeps its own preferences.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshTask = "io.github.ydkmt11arch.sahm.refresh"
    static let processTask = "io.github.ydkmt11arch.sahm.process"

    private let enabledKey = "sahm.notify.enabled"
    private let askedKey = "sahm.notify.asked"        // the system sheet was already shown once
    private let lastIdKey = "sahm.notify.lastId"
    private let shownKey = "sahm.notify.shown"        // ids already shown: never notify the same item twice
    private let unreadKey = "sahm.notify.unread"
    private let deviceKey = "sahm.notify.device"      // this install's own id (one subscriber on the server)
    private let lastURLKey = "sahm.lastURL"           // written by MainViewController after a verified connection
    private var timer: Timer?
    private var fetching = false
    private var asked = false                         // this process asked the system for permission
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// Set by the controller: the page learns the state through the event «sahm:notify».
    var onState: (([String: Any]) -> Void)?

    var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// CI (-ciNoPrompt YES): never show the system sheet, so it cannot cover a screenshot.
    private var noPrompt: Bool { UserDefaults.standard.bool(forKey: "ciNoPrompt") }
    /// iOS's permission question was answered (or skipped in CI): the page may show its own sheet now.
    var firstAskDone: Bool { noPrompt || UserDefaults.standard.bool(forKey: askedKey) }

    /// One id per install, made on first use and kept in UserDefaults. The page gets it through the bridge and sends
    /// it with its own requests, so the phone and the interface are the SAME subscriber on the server.
    var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey), !id.isEmpty { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    // MARK: - Launch and life cycle

    /// From application(_:didFinishLaunchingWithOptions:): iOS wants background handlers registered before launch ends.
    func registerAtLaunch() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.refreshTask, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Notifier.shared.runRefresh(refresh)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.processTask, using: nil) { task in
            guard let process = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Notifier.shared.runProcessing(process)
        }
    }

    /// The app is in front: ask for permission the very first time, clear the badge, fetch now and every 60 s.
    func foreground() {
        clearBadge()
        timer?.invalidate()
        timer = nil
        askOnFirstLaunch()
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Notifier.shared.fetch(background: false) }
        }
        Task { @MainActor in await self.fetch(background: false) }
        schedule()
    }

    /// The app left the screen: stop the timer and ask iOS for the next wake-up.
    func background() {
        timer?.invalidate()
        timer = nil
        schedule()
    }

    /// The native permission sheet, once, on the first launch — like any other iPhone app. If the user already
    /// answered in an older version, nothing is shown and we simply follow his answer.
    private func askOnFirstLaunch() {
        guard !noPrompt, !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .notDetermined else {
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: self.askedKey)
                    UserDefaults.standard.set(settings.authorizationStatus == .authorized, forKey: self.enabledKey)
                    self.report()
                }
                return
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: self.askedKey)
                self.asked = true
                self.request()
            }
        }
    }

    private func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(granted, forKey: self.enabledKey)
                if granted {
                    UserDefaults.standard.removeObject(forKey: self.lastIdKey)   // first sync = from now, no history
                    self.foreground()
                }
                self.report()
            }
        }
    }

    /// Both background kinds, as often as iOS allows: a refresh (short, frequent) and a processing task (longer,
    /// when the phone is idle). iOS alone decides if and when either runs; both are re-submitted after every run.
    private func schedule() {
        guard enabled else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: Notifier.refreshTask)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(refresh)        // the simulator refuses: nothing to do about it
        let process = BGProcessingTaskRequest(identifier: Notifier.processTask)
        process.requiresNetworkConnectivity = true
        process.requiresExternalPower = false
        process.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(process)
    }

    private func runRefresh(_ task: BGAppRefreshTask) {
        schedule()                                        // the next wake-up first: one failed fetch never ends the chain
        let work = Task { @MainActor in
            let ok = await Notifier.shared.fetch(background: true)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func runProcessing(_ task: BGProcessingTask) {
        schedule()
        let work = Task { @MainActor in
            let ok = await Notifier.shared.fetch(background: true)
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - The switch in the page (fallback after a refusal, or to stop them)

    func setEnabled(_ on: Bool) {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            timer?.invalidate()
            timer = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Notifier.refreshTask)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Notifier.processTask)
            report()
            return
        }
        UserDefaults.standard.set(true, forKey: askedKey)
        request()
    }

    /// Tell the page: permission, the switch, whether iOS allows background refresh, and this install's id.
    func report() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = Notifier.name(of: settings.authorizationStatus)
            DispatchQueue.main.async {
                let bg: String
                switch UIApplication.shared.backgroundRefreshStatus {
                case .available: bg = "available"
                case .denied: bg = "denied"
                case .restricted: bg = "restricted"
                @unknown default: bg = "unknown"
                }
                self.onState?(["status": status, "enabled": self.enabled, "bg": bg, "device": self.deviceId,
                               "asked": UserDefaults.standard.bool(forKey: self.askedKey)])
            }
        }
    }

    private static func name(of status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        default: return "notDetermined"
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
        var items = query
        items.append(URLQueryItem(name: "did", value: deviceId))     // this install = one subscriber on the server
        comps?.queryItems = items
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

    /// A long gap shows the newest six and one line for the rest. Each feed id is shown at most once.
    @MainActor
    private func show(_ items: [[String: Any]], more: Int) async {
        let center = UNUserNotificationCenter.current()
        var done = UserDefaults.standard.array(forKey: shownKey) as? [Int] ?? []
        let fresh = items.filter { item in
            guard let id = item["id"] as? Int else { return false }
            return !done.contains(id)
        }
        let shown = Array(fresh.suffix(6))
        let hidden = more + fresh.count - shown.count
        for item in shown {
            let id = item["id"] as? Int ?? 0
            let content = UNMutableNotificationContent()
            content.title = item["title"] as? String ?? "سهم"
            content.body = item["text"] as? String ?? ""
            content.sound = .default
            content.threadIdentifier = item["kind"] as? String ?? "sahm"
            content.badge = NSNumber(value: bumpUnread())
            try? await center.add(UNNotificationRequest(identifier: "sahm-\(id)", content: content, trigger: nil))
            done.append(id)
        }
        if !done.isEmpty {
            UserDefaults.standard.set(Array(done.suffix(80)), forKey: shownKey)
        }
        if hidden > 0 {
            let content = UNMutableNotificationContent()
            content.title = "سهم"
            content.body = "و\(hidden) تنبيهات أخرى — افتح سهم واضغط الجرس في أعلى الشاشة."
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

    /// CI only: one read of the feed (ci=1: not counted as a real phone), nothing shown, nothing stored.
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

    /// CI only: a synchronous snapshot for reports written outside an async context (the pairing panel).
    var ciSync: [String: Any] {
        ["asked": UserDefaults.standard.bool(forKey: askedKey), "prompted": asked,
         "enabled": enabled, "device_len": deviceId.count]
    }

    /// CI only: what happened with the first-launch permission sheet.
    @MainActor
    func ciState() async -> [String: Any] {
        let settings = await withCheckedContinuation { (c: CheckedContinuation<UNNotificationSettings, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0) }
        }
        return ["asked": UserDefaults.standard.bool(forKey: askedKey), "prompted": asked,
                "status": Notifier.name(of: settings.authorizationStatus), "enabled": enabled,
                "device_len": deviceId.count]
    }
}
