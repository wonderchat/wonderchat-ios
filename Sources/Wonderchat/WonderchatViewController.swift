import UIKit
import WebKit

/// The chat as a UIKit screen. `Wonderchat.openChat()` presents it as a sheet;
/// you can also push it or embed it (e.g. as a Support tab).
@MainActor
public final class WonderchatViewController: UIViewController {
    /// Called when the user taps the chat's close button while this screen
    /// was not opened with `Wonderchat.openChat()`. If nil, the screen pops
    /// itself from a navigation stack or dismisses itself when presented.
    public var onClose: (() -> Void)?

    private(set) var isChatLoaded = false
    private(set) var isVisible = false

    private var webView: WKWebView!
    private let loadingView = LoadingView()
    private let errorView = ErrorView()
    private var loadedFallback: DispatchWorkItem?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Wonderchat.shared.register(self)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = "WonderchatSDK-iOS/\(Wonderchat.version)"
        configuration.userContentController.add(ScriptHandler(owner: self), name: "wonderchat")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.accessibilityIdentifier = "wonderchat.chat"
        view.addSubview(webView)

        // Pinned to the keyboard so the composer rides above it.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        for overlay in [loadingView, errorView] as [UIView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.load() }

        load()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        Wonderchat.shared.controllerVisibilityChanged()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        Wonderchat.shared.controllerVisibilityChanged()
    }

    // MARK: Loading

    private func load() {
        guard let url = Wonderchat.shared.chatURL else {
            assertionFailure("Call Wonderchat.configure(chatbotId:) before showing the chat")
            return
        }
        isChatLoaded = false
        errorView.isHidden = true
        loadingView.show()
        webView.load(URLRequest(url: url))
    }

    func markLoaded() {
        loadedFallback?.cancel()
        let firstLoad = !isChatLoaded
        isChatLoaded = true
        errorView.isHidden = true
        if firstLoad { matchBottomColor() }
        loadingView.hide()
        Wonderchat.shared.chatLoaded(in: self)
    }

    /// Paints the strip under the web view (home indicator area) in the
    /// page's own background so the chat reads edge to edge.
    private func matchBottomColor() {
        let script = """
        (function () {
          var el = document.elementFromPoint(window.innerWidth / 2, window.innerHeight - 2);
          while (el) {
            var c = getComputedStyle(el).backgroundColor;
            if (c && c !== 'transparent' && !/rgba\\(.*,\\s*0\\)$/.test(c)) return c;
            el = el.parentElement;
          }
          return null;
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let css = result as? String, let color = UIColor(cssRGB: css) else { return }
            self.view.backgroundColor = color
        }
    }

    // MARK: Native -> web

    func identify(_ identity: [String: Any]) {
        call("window.wonderchat && window.wonderchat.identify(value)", value: identity)
    }

    func restore(_ conversation: Conversation) {
        call(
            "window.wonderchat && window.wonderchat.restoreConversation && window.wonderchat.restoreConversation(value)",
            value: ["chatlogId": conversation.chatlogId, "userToken": conversation.userToken]
        )
    }

    func send(_ text: String) {
        call("window.wonderchat && window.wonderchat.sendMessage(value)", value: text)
    }

    func clearHistory() {
        webView?.evaluateJavaScript("window.wonderchat && window.wonderchat.clearChatbotHistory();")
    }

    private func call(_ body: String, value: Any) {
        webView?.callAsyncJavaScript(body, arguments: ["value": value], in: nil, in: .page) { _ in }
    }

    // MARK: Web -> native

    fileprivate func receive(_ body: Any) {
        var message: [String: Any]?
        if let string = body as? String, let data = string.data(using: .utf8) {
            message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            message = body as? [String: Any]
        }
        guard let message, let type = message["type"] as? String else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        Wonderchat.shared.handleBridgeMessage(type, payload: payload, from: self)
    }

    func handleCloseRequest() {
        if Wonderchat.shared.isPresentedBySDK(self) {
            presentingViewController?.dismiss(animated: true)
        } else if let onClose {
            onClose()
        } else if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true)
        }
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
        } else if UIApplication.shared.canOpenURL(url) || ["mailto", "tel", "sms"].contains(scheme) {
            UIApplication.shared.open(url)
        }
    }

    private func isChatHost(_ url: URL) -> Bool {
        guard let chatHost = Wonderchat.shared.baseURL.host?.lowercased() else { return false }
        return url.host?.lowercased() == chatHost
    }
}

// MARK: - WKNavigationDelegate

extension WonderchatViewController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "blob", "data"].contains(scheme) { return decisionHandler(.allow) }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let isWeb = scheme == "http" || scheme == "https"
        if !isWeb || (isMainFrame && !isChatHost(url)) {
            // Source links, booking pages, mailto: and tel: leave the chat.
            openExternally(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Servers that predate the `chatbotLoaded` event never post it.
        loadedFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, !self.isChatLoaded else { return }
            self.loadingView.hide()
        }
        loadedFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: fallback)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
    }

    private func showError(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        // Policy-cancelled navigations (links sent to Safari) report error 102.
        if (error as NSError).domain == "WebKitErrorDomain", (error as NSError).code == 102 { return }
        guard !isChatLoaded else { return }
        loadingView.hide()
        errorView.isHidden = false
    }
}

// MARK: - WKUIDelegate

extension WonderchatViewController: WKUIDelegate {
    // Links the chat opens in a new tab (sources, booking pages) go to Safari.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentOrComplete(alert) { completionHandler() }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentOrComplete(alert) { completionHandler(false) }
    }

    private func presentOrComplete(_ alert: UIAlertController, fallback: () -> Void) {
        guard view.window != nil, presentedViewController == nil else { return fallback() }
        present(alert, animated: true)
    }
}

// MARK: - Bridge

// WKUserContentController retains its handlers; holding the controller weakly
// avoids a retain cycle.
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WonderchatViewController?

    init(owner: WonderchatViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.receive(body) }
    }
}

// MARK: - Overlays

private final class LoadingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "wonderchat.loading"
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        spinner.startAnimating()
    }

    func hide() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { finished in
            guard finished else { return }
            self.isHidden = true
            self.spinner.stopAnimating()
        })
    }
}

private final class ErrorView: UIView {
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "wonderchat.error"

        let title = UILabel()
        title.text = "Couldn't load the chat"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Check your connection and try again."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let button = UIButton(type: .system)
        button.setTitle("Try Again", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, button])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension UIColor {
    /// Parses `rgb(r, g, b)` / `rgba(r, g, b, a)` as returned by getComputedStyle.
    convenience init?(cssRGB css: String) {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        let alpha = parts.count > 3 ? parts[3] : 1
        guard alpha > 0.95 else { return nil }
        self.init(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }
}
