import UIKit
import WebKit

/// One screen. The interface — the same files as the Telegram mini app — runs from inside the app (sahmui://app/),
/// so it opens at once, keeps the last data when the PC is off, and updates itself from the PC without reinstalling
/// (WebBundle + UIUpdater). Native panels cover it only for pairing, the very first download, and the optional lock.
final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private enum Screen { case busy, pairing, offline, web }

    private var web: WKWebView!
    private let scheme = AppScheme()
    private let panel = UIView()
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let detailLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private let lockCover = UIView()

    private var screen: Screen = .busy
    private var hint: URL?
    private var hasBundledKey = false
    private var resolvedAt = Date.distantPast
    private var generation = 0
    private var watchdog: Timer?
    private var misses = 0
    private var checking = false
    private var locating = false
    private var lastLocate = Date.distantPast

    private var loaded: WebBundle.Root?
    private var pageReady = false
    private var readyTimer: Timer?
    private var justUpdated = false

    private var locked = false
    private var authenticating = false
    private var promptedThisVisit = false
    private var backgroundAt: Date?

    private var ciReports = 0
    private var ciFirstDone = false
    private var ciPending: WebBundle.Root?

    private static let lastURLKey = "sahm.lastURL"

    /// CI only: `-pointerFile p_ci.json` reads the public test pointer instead of p.json.
    private var pointerFile: String { UserDefaults.standard.string(forKey: "pointerFile") ?? "p.json" }
    private var isRealPointer: Bool { pointerFile == "p.json" }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.ground
        scheme.forceOffline = UserDefaults.standard.bool(forKey: "ciForceOffline")
        Link.shared.onUnreachable = { [weak self] in self?.unreachable() }
        buildWeb()
        buildPanel()
        buildLockCover()
        if LockGate.shared.enabled { lockNow() }
        start()
    }

    // MARK: - Flow

    func start() {
        let bundled = Bundled.applyIfNew()
        hasBundledKey = bundled != nil
        hint = bundled?.hint
        guard let key = KeyStore.read() else {
            Link.shared.key = nil
            showPairing(problem: nil)
            return
        }
        Link.shared.key = key
        if loaded == nil { showInterface() }
        if !scheme.forceOffline { connect(key) }
    }

    /// The newest copy of the interface on the phone, at once (its data comes from the phone's copy until the PC answers).
    private func showInterface() {
        if let root = WebBundle.best() {
            load(root)
        } else {
            showBusy("جاري تجهيز سهم لأول مرة…")      // no copy yet: it downloads as soon as the PC answers
        }
    }

    private func load(_ root: WebBundle.Root, updated: Bool = false) {
        loaded = root
        scheme.root = root.dir
        pageReady = false
        justUpdated = updated
        installBridge()
        web.load(URLRequest(url: AppScheme.home))
        readyTimer?.invalidate()
        readyTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            self?.readyTimedOut()
        }
    }

    /// The page never reported that it started: use another copy if there is one (this version is never tried again).
    private func readyTimedOut() {
        guard !pageReady, let current = loaded else { return }
        if let other = WebBundle.best(excluding: [current.manifest.version]) {
            WebBundle.markBad(current.manifest.version)
            load(other)
        } else {
            hidePanel()
        }
    }

    /// ydsahm://pair?k=<APP_KEY>, opened by the pairing page that the admin panel links to.
    @discardableResult
    func handle(url: URL) -> Bool {
        loadViewIfNeeded()
        guard url.scheme?.lowercased() == "ydsahm", url.host?.lowercased() == "pair",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "k" })?.value,
              PairKey.isValid(key) else { return false }
        KeyStore.save(key)
        screen = .busy
        start()
        return true
    }

    /// The scene became active: unlock if needed, check the address, and look for a newer interface.
    func resume() {
        if locked && !authenticating && !promptedThisVisit { promptUnlock() }
        refreshIfStale()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(timeInterval: 45, target: self, selector: #selector(tickTimer),
                                        userInfo: nil, repeats: true)
        if Link.shared.base != nil { update(force: false, manual: false) }      // at most every 10 minutes
    }

    /// The app went to the background: hide its content from the app switcher when the lock is on.
    func pause() {
        watchdog?.invalidate()
        watchdog = nil
        backgroundAt = Date()
        promptedThisVisit = false
        if LockGate.shared.enabled {
            lockCover.isHidden = false
            view.bringSubviewToFront(lockCover)
        }
    }

    /// Back from the background: after more than a minute away the lock asks again.
    func willForeground() {
        guard LockGate.shared.enabled else {
            lockCover.isHidden = true
            return
        }
        let away = Date().timeIntervalSince(backgroundAt ?? .distantPast)
        if away > 60 {
            locked = true
        } else if !locked {
            lockCover.isHidden = true
        }
    }

    /// Back after 5+ minutes: the PC may have restarted with a new address.
    func refreshIfStale() {
        guard let key = Link.shared.key, !scheme.forceOffline, Date().timeIntervalSince(resolvedAt) > 300 else { return }
        guard let current = Link.shared.base else {
            if !locating { connect(key) }
            return
        }
        Task { @MainActor in
            if await Pointer.healthy(current) {
                self.resolvedAt = Date()
                self.notifyPage("sahm:online")
            } else {
                self.connect(key)
            }
        }
    }

    @objc private func tickTimer() {
        tick()
    }

    /// Every 45 s in front: two failed health checks in a row -> look for a new address. Not found yet -> try again,
    /// so the app comes back by itself when the PC does.
    private func tick() {
        guard !checking, !scheme.forceOffline, let key = Link.shared.key else { return }
        guard let current = Link.shared.base else {
            if !locating { connect(key) }
            return
        }
        checking = true
        let file = pointerFile
        Task { @MainActor in
            defer { self.checking = false }
            if await Pointer.healthy(current) {
                self.misses = 0
                self.resolvedAt = Date()
                Link.shared.markUp()
                return
            }
            self.misses += 1
            guard self.misses >= 2 else { return }
            self.misses = 0
            if let fresh = try? await Pointer.fetch(pairKey: key, file: file), fresh != current,
               await Pointer.healthy(fresh) {
                self.online(fresh)
            } else {
                self.notifyPage("sahm:offline")
            }
        }
    }

    private func connect(_ key: String) {
        generation += 1
        let gen = generation
        locating = true
        lastLocate = Date()
        Task { @MainActor in
            defer {
                if gen == self.generation { self.locating = false }
            }
            do {
                let url = try await self.locate(key: key)
                guard gen == self.generation else { return }
                self.online(url)
            } catch LinkError.key {
                guard gen == self.generation else { return }
                self.showPairing(problem: "رمز الربط لم يعد صالحًا — ثبّت نسختك الجديدة من لوحة الإدارة أو الصق الرمز الجديد.")
            } catch {
                guard gen == self.generation else { return }
                self.unreachableNow(MainViewController.describe(error))
            }
        }
    }

    /// The proxy could not reach the address (the PC may have restarted): look for a new one, at most every 30 s.
    private func unreachable() {
        guard !locating, !scheme.forceOffline, let key = Link.shared.key,
              Date().timeIntervalSince(lastLocate) > 30 else { return }
        connect(key)
    }

    private func online(_ url: URL) {
        Link.shared.base = url
        resolvedAt = Date()
        misses = 0
        if isRealPointer {
            UserDefaults.standard.set(url.absoluteString, forKey: MainViewController.lastURLKey)
        }
        if loaded == nil && screen == .offline { showBusy("جاري تجهيز سهم لأول مرة…") }
        notifyPage("sahm:online")
        update(force: loaded == nil, manual: false)
    }

    /// The PC is not answering. With the interface on screen it shows the last data with its own banner;
    /// without one (the very first run) the native panel explains.
    private func unreachableNow(_ reason: String) {
        if loaded != nil {
            notifyPage("sahm:offline")
        } else {
            showOffline(reason: reason)
        }
    }

    /// The fastest live address: the last one that worked, else the encrypted pointer, else the address built into
    /// this IPA. Addresses that did not come from the pointer must first prove they hold the key.
    private func locate(key: String) async throws -> URL {
        if isRealPointer, let text = UserDefaults.standard.string(forKey: MainViewController.lastURLKey),
           let last = URL(string: text), await Pointer.proves(last, key: key) {
            return last
        }
        var failure: Error = LinkError.offline
        do {
            let url = try await Pointer.fetch(pairKey: key, file: pointerFile)
            if await Pointer.healthy(url) { return url }
        } catch LinkError.key {
            throw LinkError.key
        } catch {
            failure = error
        }
        if isRealPointer, let hinted = hint, await Pointer.proves(hinted, key: key) {
            return hinted
        }
        throw failure
    }

    /// Newer interface on the PC -> download only what changed -> switch to it. `manual` = asked from the page.
    private func update(force: Bool, manual: Bool) {
        Task { @MainActor in
            if manual { self.notifyPage("sahm:update", ["state": "checking"]) }
            let outcome = await UIUpdater.shared.check(current: self.loaded?.manifest.version, force: force || manual)
            switch outcome {
            case .installed(let root):
                let replacing = self.loaded != nil     // the very first download is not an "update"
                if self.ciEnabled && !self.ciFirstDone && replacing {
                    self.ciPending = root           // CI: report the first page before switching to the update
                } else {
                    self.load(root, updated: replacing)
                }
            case .upToDate:
                if manual { self.notifyPage("sahm:update", ["state": "current"]) }
                if self.loaded == nil { self.showOffline(reason: "لا توجد نسخة صالحة من الواجهة.") }
            case .failed(let why):
                if manual { self.notifyPage("sahm:update", ["state": "failed", "detail": why]) }
                if self.loaded == nil { self.showOffline(reason: "تعذّر تنزيل الواجهة من الكمبيوتر.") }
            case .skipped:
                if manual { self.notifyPage("sahm:update", ["state": "busy"]) }
            }
        }
    }

    private func pasteKey() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            showPairing(problem: "الحافظة فارغة — انسخ رمز الربط من لوحة الإدارة أولًا.")
            return
        }
        if let url = URL(string: raw), url.scheme?.lowercased() == "ydsahm", handle(url: url) { return }
        var key = raw
        if let marker = raw.range(of: "#k=") { key = String(raw[marker.upperBound...]) }
        guard PairKey.isValid(key) else {
            showPairing(problem: "النص المنسوخ ليس رمز ربط صالحًا.")
            return
        }
        KeyStore.save(key)
        screen = .busy
        start()
    }

    private func unpair() {
        let alert = UIAlertController(title: "إلغاء الربط؟",
                                      message: "سيحتاج التطبيق رمز ربط جديدًا من لوحة الإدارة.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "تراجع", style: .cancel))
        alert.addAction(UIAlertAction(title: "إلغاء الربط", style: .destructive) { [weak self] _ in
            KeyStore.clear()
            ApiCache.clear()
            UserDefaults.standard.removeObject(forKey: MainViewController.lastURLKey)
            Link.shared.key = nil
            Link.shared.base = nil
            self?.generation += 1
            self?.showPairing(problem: nil)
        })
        present(alert, animated: true)
    }

    @objc private func pulled() {
        notifyPage("sahm:refresh")
        if Link.shared.base == nil, let key = Link.shared.key, !locating, !scheme.forceOffline { connect(key) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.web.scrollView.refreshControl?.endRefreshing()
        }
    }

    static func describe(_ error: Error) -> String {
        if let link = error as? LinkError {
            switch link {
            case .network(let code):
                return code == 0 ? "تعذّر الوصول إلى خادم الرابط." : "خادم الرابط ردّ بالرمز \(code)."
            case .format:
                return "ملف الرابط غير مكتمل — شغّل سهم على جهاز الكمبيوتر لينشره من جديد."
            case .badURL:
                return "عنوان المنصة في ملف الرابط غير صالح."
            case .key:
                return "رمز الربط غير صالح."
            case .offline:
                return "آخر عنوان نشره جهاز الكمبيوتر لا يرد."
            }
        }
        if let url = error as? URLError {
            if url.code == .notConnectedToInternet { return "لا يوجد اتصال بالإنترنت." }
            if url.code == .timedOut { return "انتهت مهلة الاتصال." }
            return "خطأ في الشبكة (\(url.code.rawValue))."
        }
        return "خطأ غير متوقع."
    }

    // MARK: - Lock

    private func lockNow() {
        locked = true
        lockCover.isHidden = false
        view.bringSubviewToFront(lockCover)
    }

    private func promptUnlock() {
        guard locked, !authenticating else { return }
        if LockGate.shared.kind == "none" {             // the passcode was removed from the phone: nothing to ask
            LockGate.shared.enabled = false
            unlockDone()
            return
        }
        authenticating = true
        promptedThisVisit = true
        LockGate.shared.authenticate(reason: "افتح سهم") { [weak self] ok in
            guard let self = self else { return }
            self.authenticating = false
            if ok { self.unlockDone() }
        }
    }

    private func unlockDone() {
        locked = false
        UIView.animate(withDuration: 0.2, animations: { self.lockCover.alpha = 0 }, completion: { _ in
            self.lockCover.isHidden = true
            self.lockCover.alpha = 1
        })
    }

    private func setLock(_ on: Bool) {
        if !on {
            LockGate.shared.enabled = false
            notifyPage("sahm:lock", ["enabled": false, "ok": true])
            return
        }
        guard LockGate.shared.kind != "none" else {
            notifyPage("sahm:lock", ["enabled": false, "ok": false, "detail": "فعّل رمز المرور في الجوال أولًا."])
            return
        }
        authenticating = true
        LockGate.shared.authenticate(reason: "تفعيل قفل سهم") { [weak self] ok in
            guard let self = self else { return }
            self.authenticating = false
            if ok { LockGate.shared.enabled = true }
            self.notifyPage("sahm:lock", ["enabled": LockGate.shared.enabled, "ok": ok])
        }
    }

    @objc private func tapUnlock() {
        promptUnlock()
    }

    // MARK: - Panel states

    private func showBusy(_ text: String) {
        screen = .busy
        showPanel(title: nil, body: text, detail: nil, busy: true, primary: nil, secondary: nil)
    }

    private func showPairing(problem: String?) {
        screen = .pairing
        showPanel(title: "اربط التطبيق بمنصتك",
                  body: "هذه نسخة عامة غير مربوطة. لتفتح منصتك مباشرة ثبّت نسختك الخاصة: افتح سهم في تيليجرام، اضغط مطوّلًا على «الرئيسية»، ثم «تثبيت تطبيق الآيفون». أو انسخ رمز الربط من لوحة الإدارة والصقه هنا.",
                  detail: problem, detailIsError: problem != nil, busy: false,
                  primary: ("لصق رمز الربط", { [weak self] in self?.pasteKey() }),
                  secondary: nil)
    }

    private func showOffline(reason: String) {
        screen = .offline
        // built with if/else on purpose: `cond ? nil : (text, closure)` crashes the Swift 6.3 type checker
        var secondary: (String, () -> Void)?
        if !hasBundledKey {
            secondary = ("إلغاء الربط", { [weak self] in self?.unpair() })
        }
        let primary: (String, () -> Void) = ("إعادة المحاولة الآن", { [weak self] in self?.start() })
        showPanel(title: "المنصة غير متاحة الآن",
                  body: "تأكد أن جهاز الكمبيوتر يعمل وأن سهم مشغّل. يعيد التطبيق المحاولة تلقائيًا كل دقيقة تقريبًا.",
                  detail: reason, busy: false, primary: primary, secondary: secondary)
    }

    private func showPanel(title: String?, body: String?, detail: String?, detailIsError: Bool = false,
                           busy: Bool, primary: (String, () -> Void)?, secondary: (String, () -> Void)?) {
        web.scrollView.refreshControl?.endRefreshing()
        titleLabel.text = title
        titleLabel.isHidden = title == nil
        bodyLabel.text = body
        bodyLabel.isHidden = body == nil
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        detailLabel.textColor = detailIsError ? Theme.loss : Theme.muted
        if busy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        spinner.isHidden = !busy
        primaryButton.setTitle(primary?.0, for: .normal)
        primaryButton.isHidden = primary == nil
        primaryAction = primary?.1
        secondaryButton.setTitle(secondary?.0, for: .normal)
        secondaryButton.isHidden = secondary == nil
        secondaryAction = secondary?.1
        panel.layer.removeAllAnimations()
        panel.alpha = 1
        panel.isHidden = false
        view.bringSubviewToFront(panel)
        if !lockCover.isHidden { view.bringSubviewToFront(lockCover) }
        if !busy {
            ciWrite(["stage": "panel", "title": title ?? "", "body": body ?? "", "detail": detail ?? ""])
        }
    }

    private func hidePanel() {
        guard screen != .pairing, !panel.isHidden else {
            if screen != .pairing { screen = .web }
            return
        }
        screen = .web
        UIView.animate(withDuration: 0.25, animations: { self.panel.alpha = 0 }, completion: { _ in
            if self.panel.alpha == 0 {
                self.panel.isHidden = true
                self.spinner.stopAnimating()
            }
        })
    }

    @objc private func tapPrimary() { primaryAction?() }
    @objc private func tapSecondary() { secondaryAction?() }

    // MARK: - Page bridge

    /// window.SahmApp: what the page knows about the app, and what it can ask of it.
    private func installBridge() {
        let info = Bundle.main.infoDictionary ?? [:]
        let manifest = loaded?.manifest
        let ui: [String: Any] = ["version": String((manifest?.version ?? "").prefix(12)),
                                 "builtAt": manifest?.builtAt ?? "",
                                 "builtIn": loaded?.builtIn ?? false,
                                 "updated": justUpdated]
        let lock: [String: Any] = ["kind": LockGate.shared.kind, "enabled": LockGate.shared.enabled]
        var payload: [String: Any] = ["platform": "ios"]
        payload["version"] = info["CFBundleShortVersionString"] as? String ?? "?"
        payload["build"] = info["CFBundleVersion"] as? String ?? "?"
        payload["ui"] = ui
        payload["lock"] = lock
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let source = """
        (function () {
          var info = \(json);
          function post(m) { try { window.webkit.messageHandlers.sahm.postMessage(m); } catch (e) {} }
          info.haptic = function (kind) { post({ haptic: String(kind || "medium") }); };
          info.ready = function () { post({ ready: true }); };
          info.setLock = function (on) { post({ lock: !!on }); };
          info.checkUpdate = function () { post({ checkUpdate: true }); };
          info.openExternal = function (url) { post({ open: String(url) }); };
          info.share = function (text, url) { post({ share: { text: String(text || ""), url: String(url || "") } }); };
          window.SahmApp = Object.freeze(info);
        })();
        """
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private func notifyPage(_ name: String, _ detail: [String: Any] = [:]) {
        guard loaded != nil else { return }
        let data = (try? JSONSerialization.data(withJSONObject: detail)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(name)', { detail: \(json) }))",
                               completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let kind = body["haptic"] as? String { haptic(kind) }
        if body["ready"] != nil { pageStarted() }
        if let on = body["lock"] as? Bool { setLock(on) }
        if body["checkUpdate"] != nil { update(force: true, manual: true) }
        if let text = body["open"] as? String, let url = URL(string: text),
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        if let item = body["share"] as? [String: Any] { share(item) }
    }

    private func pageStarted() {
        guard !pageReady else { return }
        pageReady = true
        readyTimer?.invalidate()
        hidePanel()
        ciStage()
    }

    private func haptic(_ kind: String) {
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "select": UISelectionFeedbackGenerator().selectionChanged()
        default: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func share(_ item: [String: Any]) {
        var items: [Any] = []
        if let text = item["text"] as? String, !text.isEmpty { items.append(text) }
        if let link = item["url"] as? String, let url = URL(string: link), url.scheme == "https" { items.append(url) }
        guard !items.isEmpty, presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    // MARK: - Views

    private func buildWeb() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.setURLSchemeHandler(scheme, forURLScheme: AppScheme.name)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        config.applicationNameForUserAgent = "SahmApp/\(version)"
        config.allowsInlineMediaPlayback = true
        // retained by the content controller: fine, this controller is the app's root for its whole life
        config.userContentController.add(self, name: "sahm")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = Theme.ground
        webView.scrollView.backgroundColor = Theme.ground
        webView.scrollView.contentInsetAdjustmentBehavior = .never     // the page lays out its own safe areas
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        pin(webView)
        let refresh = UIRefreshControl()
        refresh.tintColor = Theme.sand
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        web = webView
    }

    private func pin(_ child: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func buildPanel() {
        panel.backgroundColor = Theme.ground
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.semanticContentAttribute = .forceRightToLeft
        view.addSubview(panel)
        pin(panel)

        let logo = UILabel()
        logo.text = "سهم"
        logo.font = .systemFont(ofSize: 46, weight: .heavy)
        logo.textColor = Theme.sand
        logo.textAlignment = .center

        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = Theme.ink
        bodyLabel.font = .systemFont(ofSize: 16)
        bodyLabel.textColor = Theme.muted
        detailLabel.font = .systemFont(ofSize: 14)
        for label in [titleLabel, bodyLabel, detailLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        spinner.color = Theme.sand
        spinner.hidesWhenStopped = false
        style(primaryButton, filled: true)
        style(secondaryButton, filled: false)
        primaryButton.addTarget(self, action: #selector(tapPrimary), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(tapSecondary), for: .touchUpInside)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.semanticContentAttribute = .forceRightToLeft
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in [logo, spinner, titleLabel, bodyLabel, primaryButton, secondaryButton, detailLabel] as [UIView] {
            stack.addArrangedSubview(item)
        }
        stack.setCustomSpacing(28, after: logo)
        stack.setCustomSpacing(22, after: bodyLabel)
        panel.addSubview(stack)
        let guide = panel.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
        ])
    }

    private func buildLockCover() {
        lockCover.backgroundColor = Theme.ground
        lockCover.isHidden = true
        lockCover.translatesAutoresizingMaskIntoConstraints = false
        lockCover.semanticContentAttribute = .forceRightToLeft
        view.addSubview(lockCover)
        pin(lockCover)
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = Theme.muted
        icon.contentMode = .scaleAspectFit
        let logo = UILabel()
        logo.text = "سهم"
        logo.font = .systemFont(ofSize: 46, weight: .heavy)
        logo.textColor = Theme.sand
        logo.textAlignment = .center
        let button = UIButton(type: .system)
        style(button, filled: true)
        button.setTitle("افتح سهم", for: .normal)
        button.addTarget(self, action: #selector(tapUnlock), for: .touchUpInside)
        let column = UIStackView(arrangedSubviews: [icon, logo, button])
        column.axis = .vertical
        column.spacing = 18
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        lockCover.addSubview(column)
        let guide = lockCover.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 34),
            column.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 40),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -40),
        ])
    }

    private func style(_ button: UIButton, filled: Bool) {
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.layer.cornerRadius = 14
        let height = button.heightAnchor.constraint(equalToConstant: 52)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        if filled {
            button.backgroundColor = Theme.sand
            button.setTitleColor(Theme.sandInk, for: .normal)
        } else {
            button.backgroundColor = Theme.surface
            button.setTitleColor(Theme.ink, for: .normal)
            button.layer.borderWidth = 1
            button.layer.borderColor = Theme.line.cgColor
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let kind = url.scheme?.lowercased() ?? ""
        if kind == AppScheme.name || ["about", "data", "blob"].contains(kind) {
            decisionHandler(.allow)
            return
        }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        UIApplication.shared.open(url)          // other sites and app links open outside (Safari, SideStore)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.scrollView.refreshControl?.endRefreshing()
        hidePanel()
        // an interface that never calls SahmApp.ready(): the CI report still runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, !self.pageReady else { return }
            self.ciStage()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func navigationFailed(_ error: Error) {
        web.scrollView.refreshControl?.endRefreshing()
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // our own cancel of an outside link
        if let current = loaded, let other = WebBundle.best(excluding: [current.manifest.version]) {
            WebBundle.markBad(current.manifest.version)
            load(other)
            return
        }
        showOffline(reason: "تعذّر فتح الواجهة (\(ns.code)).")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.lowercased() != AppScheme.name {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "حسنًا", style: .default) { _ in completionHandler() })
        presentAlert(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(true) })
        presentAlert(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "موافق", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presentAlert(alert) { completionHandler(nil) }
    }

    /// WebKit requires the completion handler to be called: when an alert cannot be shown, answer at once.
    private func presentAlert(_ alert: UIAlertController, orElse fallback: @escaping () -> Void) {
        guard presentedViewController == nil, view.window != nil else {
            fallback()
            return
        }
        present(alert, animated: true)
    }

    // MARK: - CI self-report (only with the launch argument -ciReport YES; inert in normal use)

    private var ciEnabled: Bool { UserDefaults.standard.bool(forKey: "ciReport") }

    private var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }

    private func ciWrite(_ report: [String: Any]) {
        guard ciEnabled, let dir = documents,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("ci.json"), options: .atomic)
    }

    /// One report per page start: "home" (or -ciStage) for the first, "updated" after an interface update.
    private func ciStage() {
        guard ciEnabled else { return }
        ciReports += 1
        let first = ciReports == 1
        let stage = justUpdated ? "updated" : (UserDefaults.standard.string(forKey: "ciStage") ?? "home")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.ciProbe(stage: stage) {
                guard let self = self else { return }
                if !self.ciFirstDone {
                    self.ciFirstDone = true
                    if let pending = self.ciPending {
                        self.ciPending = nil
                        self.load(pending, updated: true)
                        return
                    }
                }
                if first && stage == "home" { self.ciAwaitNext(attempt: 0) }
            }
        }
    }

    private func ciProbe(stage: String, then next: (() -> Void)? = nil) {
        web.evaluateJavaScript(MainViewController.probeJS) { [weak self] result, error in
            var report: [String: Any] = ["stage": stage]
            if let text = result as? String, let data = text.data(using: .utf8),
               let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                report.merge(probe) { _, new in new }
            } else {
                report["probe_error"] = error.map { String(describing: $0) } ?? "no result"
            }
            self?.ciWrite(report)
            next?()
        }
    }

    /// CI writes Documents/ci-next after its screenshot; then the app long-presses «الرئيسية» as a finger would.
    private func ciAwaitNext(attempt: Int) {
        guard UserDefaults.standard.bool(forKey: "ciAdmin"), attempt < 240, let dir = documents else { return }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("ci-next").path) {
            web.evaluateJavaScript(MainViewController.longPressJS) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self?.ciProbe(stage: "admin")
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.ciAwaitNext(attempt: attempt + 1)
        }
    }

    private static let probeJS = """
    (() => {
      const b = document.body ? document.body.innerText : "";
      const sheet = document.querySelector("#admin-sheet");
      const adm = document.querySelector("#admin-body");
      const at = adm ? adm.innerText : "";
      const app = window.SahmApp || {};
      const ui = app.ui || {};
      const off = document.querySelector("#offline");
      return JSON.stringify({
        scheme: location.protocol,
        key_in_url: location.search.indexOf("key=") >= 0,
        bridge: !!window.SahmApp,
        ui_version: ui.version || "",
        ui_builtin: !!ui.builtIn,
        ui_updated: !!ui.updated,
        ci_marker: document.body ? (document.body.getAttribute("data-ci") || "") : "",
        proxy: document.body ? (document.body.getAttribute("data-proxy") || "") : "",
        offline: !!off && off.classList.contains("show"),
        offline_text: off ? off.innerText : "",
        strategies: b.indexOf("الاستراتيجيات") >= 0,
        q1: b.indexOf("Q1") >= 0,
        m1: b.indexOf("M1") >= 0,
        goal: b.indexOf("2,000") >= 0,
        auth_error: b.indexOf("غير مصرح") >= 0,
        conn_error: b.indexOf("تعذّر الاتصال") >= 0,
        nav_buttons: document.querySelectorAll("nav.tabs button").length,
        admin_open: !!sheet && !sheet.hidden,
        admin_title: at.indexOf("لوحة الإدارة") >= 0,
        admin_in_app: at.indexOf("داخل تطبيق الآيفون") >= 0,
        admin_denied: at.indexOf("للمالك فقط") >= 0 || at.indexOf("غير مصرح") >= 0,
        text_len: b.length
      });
    })()
    """

    private static let longPressJS = """
    (() => {
      const h = document.querySelector('nav.tabs button[data-tab="home"]');
      if (!h) return "no-home";
      h.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", isPrimary: true }));
      return "pressed";
    })()
    """
}
