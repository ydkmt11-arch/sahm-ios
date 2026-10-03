import UIKit
import WebKit

/// One screen: the platform (web app) in a WKWebView, with a native panel on top for pairing, connecting and errors.
final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
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

    private var base: URL?
    private var resolvedAt = Date.distantPast
    private var generation = 0

    /// CI only: launching with `-pointerFile p_ci.json` reads the public test pointer instead of p.json.
    private var pointerFile: String { UserDefaults.standard.string(forKey: "pointerFile") ?? "p.json" }

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
        if let key = KeyStore.read() {
            connect(key)
        } else {
            showPairing(problem: nil)
        }
    }

    /// sahm://pair?k=<APP_KEY>, opened by the pairing page that the admin panel links to.
    @discardableResult
    func handle(url: URL) -> Bool {
        loadViewIfNeeded()
        guard url.scheme?.lowercased() == "sahm", url.host?.lowercased() == "pair",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "k" })?.value,
              Self.isValidKey(key) else { return false }
        KeyStore.save(key)
        connect(key)
        return true
    }

    /// Back from the background after 5+ minutes: the PC may have restarted with a new address.
    func refreshIfStale() {
        guard let current = base, let key = KeyStore.read(),
              Date().timeIntervalSince(resolvedAt) > 300 else { return }
        Task { @MainActor in
            if await Pointer.healthy(current) {
                self.resolvedAt = Date()
            } else {
                self.connect(key)
            }
        }
    }

    static func isValidKey(_ key: String) -> Bool {
        (16...128).contains(key.count) && key.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }
    }

    private func connect(_ key: String) {
        generation += 1
        let gen = generation
        let file = pointerFile
        showBusy("جاري الاتصال بالمنصة…")
        Task { @MainActor in
            do {
                let url = try await Pointer.fetch(pairKey: key, file: file)
                guard gen == self.generation else { return }
                let alive = await Pointer.healthy(url)
                guard gen == self.generation else { return }
                guard alive else {
                    self.showOffline(reason: "آخر عنوان نشره جهاز الكمبيوتر لا يرد.")
                    return
                }
                self.base = url
                self.resolvedAt = Date()
                self.load(url, key: key)
            } catch LinkError.key {
                guard gen == self.generation else { return }
                self.showPairing(problem: "رمز الربط لم يعد صالحًا — اربط التطبيق من جديد من لوحة الإدارة.")
            } catch {
                guard gen == self.generation else { return }
                self.showOffline(reason: Self.describe(error))
            }
        }
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
        if let url = URL(string: raw), url.scheme?.lowercased() == "sahm", handle(url: url) { return }
        var key = raw
        if let marker = raw.range(of: "#k=") { key = String(raw[marker.upperBound...]) }
        guard Self.isValidKey(key) else {
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
                return "ملف الرابط غير مكتمل — شغّل سهم على جهاز الكمبيوتر ليُنشره من جديد."
            case .badURL:
                return "عنوان المنصة في ملف الرابط غير صالح."
            case .key:
                return "رمز الربط غير صالح."
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
        showPanel(title: nil, body: text, detail: nil, busy: true, primary: nil, secondary: nil)
    }

    private func showPairing(problem: String?) {
        showPanel(title: "اربط التطبيق بمنصتك",
                  body: "على هذا الآيفون افتح سهم في تيليجرام، اضغط مطوّلًا على «الرئيسية» لفتح لوحة الإدارة، ثم «ربط تطبيق الآيفون».",
                  detail: problem, detailIsError: problem != nil, busy: false,
                  primary: ("لصق رمز الربط", { [weak self] in self?.pasteKey() }),
                  secondary: nil)
    }

    private func showOffline(reason: String) {
        showPanel(title: "المنصة غير متاحة الآن",
                  body: "تأكد أن جهاز الكمبيوتر يعمل وأن سهم مشغّل، ثم أعد المحاولة.",
                  detail: reason, busy: false,
                  primary: ("إعادة المحاولة", { [weak self] in self?.start() }),
                  secondary: ("إلغاء الربط", { [weak self] in self?.unpair() }))
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
    }

    private func hidePanel() {
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
        config.applicationNameForUserAgent = "SahmApp/1.0"
        config.allowsInlineMediaPlayback = true
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
        UIApplication.shared.open(url)          // other sites (charts sources, Telegram links) open in Safari
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.scrollView.refreshControl?.endRefreshing()
        hidePanel()
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
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // our own cancel of an external link
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
}
