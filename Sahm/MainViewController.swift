import UIKit
import WebKit

/// One screen: the platform — the same mini app the owner opens in Telegram — in a WKWebView, with a native
/// panel on top for pairing, connecting and errors.
final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private enum Screen { case busy, pairing, offline, web }

    private var web: WKWebView!
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

    private var screen: Screen = .busy
    private var base: URL?
    private var hint: URL?
    private var hasBundledKey = false
    private var resolvedAt = Date.distantPast
    private var generation = 0
    private var watchdog: Timer?
    private var misses = 0
    private var checking = false
    private var ciStarted = false

    private static let lastURLKey = "sahm.lastURL"

    /// CI only: `-pointerFile p_ci.json` reads the public test pointer instead of p.json.
    private var pointerFile: String { UserDefaults.standard.string(forKey: "pointerFile") ?? "p.json" }
    private var isRealPointer: Bool { pointerFile == "p.json" }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.ground
        buildWeb()
        buildPanel()
        start()
    }

    // MARK: - Flow

    func start() {
        let bundled = Bundled.applyIfNew()
        hasBundledKey = bundled != nil
        hint = bundled?.hint
        if let key = KeyStore.read() {
            connect(key)
        } else {
            showPairing(problem: nil)
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
        connect(key)
        return true
    }

    /// The scene became active: check the address now, then every 45 s while the app is in front.
    func resume() {
        refreshIfStale()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(timeInterval: 45, target: self, selector: #selector(tickTimer),
                                        userInfo: nil, repeats: true)
    }

    func pause() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Back after 5+ minutes away: the PC may have restarted with a new address.
    func refreshIfStale() {
        guard screen == .web, let current = base, let key = KeyStore.read(),
              Date().timeIntervalSince(resolvedAt) > 300 else { return }
        Task { @MainActor in
            if await Pointer.healthy(current) {
                self.resolvedAt = Date()
            } else {
                self.connect(key)
            }
        }
    }

    @objc private func tickTimer() {
        tick()
    }

    /// While the page is shown: two failed health checks in a row -> look for a new address and move to it.
    /// While the offline panel is shown: retry quietly, so the app comes back by itself when the PC does.
    private func tick() {
        guard !checking, let key = KeyStore.read() else { return }
        switch screen {
        case .web:
            guard let current = base else { return }
            checking = true
            let file = pointerFile
            Task { @MainActor in
                defer { self.checking = false }
                if await Pointer.healthy(current) {
                    self.misses = 0
                    self.resolvedAt = Date()
                    return
                }
                self.misses += 1
                guard self.misses >= 2 else { return }
                self.misses = 0
                guard let fresh = try? await Pointer.fetch(pairKey: key, file: file), fresh != current,
                      await Pointer.healthy(fresh) else { return }
                self.use(fresh, key: key)
            }
        case .offline:
            checking = true
            let gen = generation
            Task { @MainActor in
                defer { self.checking = false }
                guard let url = try? await self.locate(key: key), gen == self.generation,
                      self.screen == .offline else { return }
                self.use(url, key: key)
            }
        case .busy, .pairing:
            return
        }
    }

    private func connect(_ key: String) {
        generation += 1
        let gen = generation
        showBusy("جاري الاتصال بالمنصة…")
        Task { @MainActor in
            do {
                let url = try await self.locate(key: key)
                guard gen == self.generation else { return }
                self.use(url, key: key)
            } catch LinkError.key {
                guard gen == self.generation else { return }
                self.showPairing(problem: "رمز الربط لم يعد صالحًا — ثبّت نسختك الجديدة من لوحة الإدارة أو الصق الرمز الجديد.")
            } catch {
                guard gen == self.generation else { return }
                self.showOffline(reason: Self.describe(error))
            }
        }
    }

    /// The fastest live address: the last one that worked, else the encrypted pointer, else the address built into
    /// this IPA. Addresses that did not come from the pointer must first prove they hold the key.
    private func locate(key: String) async throws -> URL {
        if isRealPointer, let text = UserDefaults.standard.string(forKey: Self.lastURLKey),
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

    private func use(_ url: URL, key: String) {
        base = url
        resolvedAt = Date()
        misses = 0
        if isRealPointer {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
        }
        load(url, key: key)
    }

    private func load(_ base: URL, key: String) {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            showOffline(reason: "عنوان المنصة غير صالح.")
            return
        }
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = parts.url else {
            showOffline(reason: "عنوان المنصة غير صالح.")
            return
        }
        showBusy("جاري فتح سهم…")
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
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
        connect(key)
    }

    private func unpair() {
        let alert = UIAlertController(title: "إلغاء الربط؟",
                                      message: "سيحتاج التطبيق رمز ربط جديدًا من لوحة الإدارة.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "تراجع", style: .cancel))
        alert.addAction(UIAlertAction(title: "إلغاء الربط", style: .destructive) { [weak self] _ in
            KeyStore.clear()
            UserDefaults.standard.removeObject(forKey: Self.lastURLKey)
            self?.base = nil
            self?.generation += 1
            self?.showPairing(problem: nil)
        })
        present(alert, animated: true)
    }

    @objc private func pulled() {
        guard let key = KeyStore.read() else {
            web.scrollView.refreshControl?.endRefreshing()
            return
        }
        guard let current = base else {
            connect(key)
            return
        }
        Task { @MainActor in
            if await Pointer.healthy(current) {
                self.web.reload()
            } else {
                self.connect(key)
            }
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
        showPanel(title: "المنصة غير متاحة الآن",
                  body: "تأكد أن جهاز الكمبيوتر يعمل وأن سهم مشغّل. يعيد التطبيق المحاولة تلقائيًا كل دقيقة تقريبًا.",
                  detail: reason, busy: false,
                  primary: ("إعادة المحاولة الآن", { [weak self] in self?.start() }),
                  secondary: hasBundledKey ? nil : ("إلغاء الربط", { [weak self] in self?.unpair() }))
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
        if !busy {
            ciWrite(["stage": "panel", "title": title ?? "", "body": body ?? "", "detail": detail ?? ""])
        }
    }

    private func hidePanel() {
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

    // MARK: - Views

    private func buildWeb() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        config.applicationNameForUserAgent = "SahmApp/\(version)"
        config.allowsInlineMediaPlayback = true
        // window.SahmApp tells the page it runs inside this app (native haptics, no Telegram chrome)
        let bridge = """
        window.SahmApp = Object.freeze({ platform: "ios", version: "\(version)", build: "\(build)",
          haptic: function (kind) { try { window.webkit.messageHandlers.sahm.postMessage({ haptic: String(kind || "medium") }); } catch (e) {} } });
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        // retained by the content controller: fine, this controller is the app's root for its whole life
        config.userContentController.add(self, name: "sahm")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = Theme.ground
        webView.scrollView.backgroundColor = Theme.ground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let refresh = UIRefreshControl()
        refresh.tintColor = Theme.sand
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        web = webView
    }

    private func buildPanel() {
        panel.backgroundColor = Theme.ground
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.semanticContentAttribute = .forceRightToLeft
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

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

    // MARK: - Native bridge (haptics from the page)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["haptic"] as? String else { return }
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) || (url.host != nil && url.host == base?.host) {
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
        ciPageLoaded()
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
        showOffline(reason: "تعذّر فتح المنصة (\(ns.code)).")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
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

    private func ciPageLoaded() {
        guard ciEnabled, !ciStarted else { return }
        ciStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.ciProbe(stage: "home") { self?.ciAwaitNext(attempt: 0) }
        }
    }

    private func ciProbe(stage: String, then next: (() -> Void)? = nil) {
        web.evaluateJavaScript(Self.probeJS) { [weak self] result, error in
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
            web.evaluateJavaScript(Self.longPressJS) { [weak self] _, _ in
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
      return JSON.stringify({
        https: location.protocol === "https:",
        key_in_url: location.search.indexOf("key=") >= 0,
        bridge: !!window.SahmApp,
        pair_page: b.indexOf("هذه الصفحة تربط") >= 0,
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
