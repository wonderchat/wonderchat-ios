// Wonderchat iOS SDK. iOS 15+, no dependencies.

import Combine
import SwiftUI
import UIKit
import UserNotifications
import WebKit

/// Entry point of the Wonderchat SDK.
///
/// Everything is available as static calls (`Wonderchat.openChat()`), and
/// `Wonderchat.shared` is an `ObservableObject` whose `unreadCount` and
/// `isChatOpen` drive SwiftUI views:
///
/// ```swift
/// @ObservedObject private var wonderchat = Wonderchat.shared
/// Text("\(wonderchat.unreadCount)")
/// ```
@MainActor
public final class Wonderchat: ObservableObject {
    public static let version = "1.0.0"

    /// Observable SDK state for SwiftUI.
    public static let shared = Wonderchat()

    /// Posted on the main thread whenever `unreadCount` changes.
    /// `userInfo["unreadCount"]` holds the new value as an `Int`.
    public static let unreadCountDidChangeNotification = Notification.Name("WonderchatUnreadCountDidChange")

    /// Team replies the user has not seen yet. Zero while the chat is open.
    @Published public private(set) var unreadCount = 0 {
        didSet {
            guard unreadCount != oldValue else { return }
            NotificationCenter.default.post(
                name: Self.unreadCountDidChangeNotification,
                object: self,
                userInfo: ["unreadCount": unreadCount]
            )
        }
    }

    /// True while a chat screen (sheet or embedded view) is on screen.
    @Published public private(set) var isChatOpen = false

    /// How often the unread count is checked while the app is active and the
    /// chat is closed. Set to 0 to only refresh on launch, foreground, chat
    /// close and push.
    public var unreadPollingInterval: TimeInterval = 60 {
        didSet { scheduleUnreadPolling() }
    }

    // MARK: State

    var chatbotId: String?
    var baseURL = URL(string: "https://app.wonderchat.io")!
    private var identity: [String: Any]?
    private var pushToken: String?
    private var conversation: Conversation?
    private var registeredKey: String?
    private var clearHistoryOnNextLoad = false
    private var pendingMessages: [String] = []
    private var unreadTask: URLSessionDataTask?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let controllers = NSHashTable<WonderchatViewController>.weakObjects()
    private weak var presentedController: WonderchatViewController?
    private var pendingOpenAttempts = 0

    private init() {}

    // MARK: Public API

    /// Call once at launch, e.g. in your SwiftUI `App` init or
    /// `application(_:didFinishLaunchingWithOptions:)`. Restores the user's
    /// conversation from the previous launch and refreshes the unread count.
    public static func configure(chatbotId: String, baseURL: URL? = nil) {
        shared.configure(chatbotId: chatbotId, baseURL: baseURL)
    }

    /// Attach who the user is so your team sees it in the inbox. Applied every
    /// time the chat loads. Values are strings, truncated to 100 characters.
    public static func identify(
        email: String? = nil,
        name: String? = nil,
        phoneNumber: String? = nil,
        custom: [String: String]? = nil
    ) {
        var payload: [String: Any] = [:]
        if let email { payload["email"] = email }
        if let name { payload["name"] = name }
        if let phoneNumber { payload["phoneNumber"] = phoneNumber }
        if let custom { payload["custom"] = custom }
        shared.identity = payload
        shared.loadedControllers.forEach { $0.identify(payload) }
    }

    /// Presents the chat as a page sheet over the top-most view controller.
    /// Does nothing if the SDK's chat sheet is already showing.
    public static func openChat(from presenter: UIViewController? = nil) {
        shared.openChat(from: presenter)
    }

    /// Same as `openChat(from:)`. Kept for compatibility.
    public static func present(from presenter: UIViewController? = nil) {
        shared.openChat(from: presenter)
    }

    /// Dismisses the chat sheet opened by `openChat()`.
    public static func closeChat(animated: Bool = true) {
        guard let controller = shared.presentedController else { return }
        controller.presentingViewController?.dismiss(animated: animated)
    }

    /// Sends `text` as the user. If the chat is not loaded yet, the message is
    /// queued and sent the next time the chat finishes loading.
    public static func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        shared.pendingMessages.append(text)
        shared.flushPendingMessages()
    }

    /// Current unread count. Observe `Wonderchat.shared` or
    /// `unreadCountDidChangeNotification` for changes.
    public static var unreadCount: Int { shared.unreadCount }

    /// Whether a chat screen is visible.
    public static var isChatOpen: Bool { shared.isChatOpen }

    /// Fetches the unread count from Wonderchat. Called automatically on
    /// configure, when the app returns to the foreground, when the chat closes
    /// and when a Wonderchat notification arrives.
    public static func refreshUnread() {
        shared.refreshUnread()
    }

    /// Forward the APNs token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setPushToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != shared.pushToken else { return }
        shared.pushToken = token
        shared.registerDeviceIfReady()
    }

    /// True when a notification was sent by Wonderchat (a reply from your team).
    public nonisolated static func isWonderchatNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["wonderchat"] != nil
    }

    /// Handles a Wonderchat notification: refreshes the unread count and, when
    /// `openChat` is true (the user tapped it), opens the chat. Returns false,
    /// doing nothing, for notifications that are not from Wonderchat.
    @discardableResult
    public static func handleNotification(_ userInfo: [AnyHashable: Any], openChat: Bool = true) -> Bool {
        guard isWonderchatNotification(userInfo) else { return false }
        if openChat {
            shared.openChat(from: nil)
        } else {
            shared.refreshUnread()
        }
        return true
    }

    /// Call when the user signs out. Forgets the identity, the conversation and
    /// the push registration; the next chat starts empty.
    public static func reset() {
        shared.reset()
    }

    // MARK: Lifecycle

    private func configure(chatbotId: String, baseURL: URL?) {
        if let baseURL { self.baseURL = baseURL }
        if self.chatbotId != chatbotId {
            self.chatbotId = chatbotId
            let stored = Storage.load(chatbotId: chatbotId)
            conversation = stored.conversation
            registeredKey = stored.registeredKey
            clearHistoryOnNextLoad = stored.clearHistoryOnNextLoad
            unreadCount = 0
        }
        if observers.isEmpty { observeApp() }
        registerDeviceIfReady()
        refreshUnread()
        scheduleUnreadPolling()
    }

    private func observeApp() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Wonderchat.shared.refreshUnread()
                Wonderchat.shared.scheduleUnreadPolling()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Wonderchat.shared.stopUnreadPolling() }
        })
    }

    private func reset() {
        identity = nil
        conversation = nil
        registeredKey = nil
        pendingMessages.removeAll()
        unreadTask?.cancel()
        unreadCount = 0
        clearHistoryOnNextLoad = true
        let loaded = loadedControllers
        if !loaded.isEmpty {
            loaded.forEach { $0.clearHistory() }
            clearHistoryOnNextLoad = false
        } else if let host = baseURL.host {
            // The page keeps the conversation in its own storage; drop it too.
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.fetchDataRecords(ofTypes: types) { records in
                let matching = records.filter { host.hasSuffix($0.displayName) }
                store.removeData(ofTypes: types, for: matching) {}
            }
        }
        persist()
        removeDeliveredNotifications()
    }

    // MARK: Opening

    private func openChat(from presenter: UIViewController?) {
        guard chatbotId != nil else {
            assertionFailure("Call Wonderchat.configure(chatbotId:) before opening the chat")
            return
        }
        if presentedController != nil { return }
        guard let host = presenter ?? Self.topViewController(), host.view.window != nil,
              !host.isBeingDismissed, !host.isBeingPresented else {
            // Cold launch from a notification tap: the window is not ready yet.
            guard pendingOpenAttempts < 20 else { pendingOpenAttempts = 0; return }
            pendingOpenAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Wonderchat.shared.openChat(from: presenter)
            }
            return
        }
        pendingOpenAttempts = 0
        let controller = WonderchatViewController()
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presentedController = controller
        host.present(controller, animated: true)
    }

    // MARK: Chat screens

    var chatURL: URL? {
        guard let chatbotId else { return nil }
        let url = baseURL.appendingPathComponent("chatbot").appendingPathComponent(chatbotId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "wcHost", value: "ios")]
        return components?.url
    }

    private var loadedControllers: [WonderchatViewController] {
        controllers.allObjects.filter(\.isChatLoaded)
    }

    func register(_ controller: WonderchatViewController) {
        controllers.add(controller)
    }

    func controllerVisibilityChanged() {
        let open = controllers.allObjects.contains(where: \.isVisible)
        guard open != isChatOpen else { return }
        isChatOpen = open
        if open {
            unreadCount = 0
            unreadTask?.cancel()
            stopUnreadPolling()
            removeDeliveredNotifications()
        } else {
            refreshUnread()
            scheduleUnreadPolling()
        }
    }

    func isPresentedBySDK(_ controller: WonderchatViewController) -> Bool {
        presentedController === controller
    }

    func chatLoaded(in controller: WonderchatViewController) {
        if clearHistoryOnNextLoad {
            controller.clearHistory()
            clearHistoryOnNextLoad = false
            persist()
        } else if let conversation {
            // The page has no embed script to hand it the conversation, so the
            // SDK restores it; identify and queued messages then land on it.
            controller.restore(conversation)
        }
        if let identity { controller.identify(identity) }
        flushPendingMessages()
    }

    private func flushPendingMessages() {
        guard !pendingMessages.isEmpty else { return }
        let loaded = loadedControllers
        guard let target = loaded.first(where: \.isVisible) ?? loaded.first else { return }
        let messages = pendingMessages
        pendingMessages.removeAll()
        messages.forEach { target.send($0) }
    }

    func handleBridgeMessage(_ type: String, payload: [String: Any], from controller: WonderchatViewController) {
        switch type {
        case "chatbotLoaded":
            controller.markLoaded()
        case "chatlogToken":
            guard let chatlogId = payload["chatlogId"] as? String,
                  let userToken = payload["userToken"] as? String,
                  !chatlogId.isEmpty, !userToken.isEmpty else { return }
            if let chatbotId = payload["chatbotId"] as? String, chatbotId != self.chatbotId { return }
            // After reset() the page may restore the old conversation before
            // the SDK has cleared it; don't adopt it again.
            if clearHistoryOnNextLoad { return }
            let next = Conversation(chatlogId: chatlogId, userToken: userToken)
            guard next != conversation else { return }
            conversation = next
            persist()
            registerDeviceIfReady()
        case "newConversation":
            conversation = nil
            persist()
        case "closeChat":
            controller.handleCloseRequest()
        default:
            break
        }
    }

    // MARK: Network

    private func registerDeviceIfReady() {
        guard let chatbotId, let pushToken, let conversation else { return }
        let key = "\(conversation.chatlogId):\(pushToken)"
        guard key != registeredKey else { return }
        registeredKey = key
        post("api/mobile/register-device", body: [
            "chatbotId": chatbotId,
            "chatlogId": conversation.chatlogId,
            "userToken": conversation.userToken,
            "pushToken": pushToken,
            "provider": "APNS",
        ]) { status, _ in
            let sdk = Wonderchat.shared
            if status == 200 {
                sdk.persist()
            } else if sdk.registeredKey == key {
                // Retried the next time a token or conversation arrives.
                sdk.registeredKey = nil
            }
        }
    }

    private func refreshUnread() {
        guard !isChatOpen, let chatbotId, let conversation else { return }
        unreadTask?.cancel()
        unreadTask = post("api/mobile/unread", body: [
            "chatbotId": chatbotId,
            "chatlogId": conversation.chatlogId,
            "userToken": conversation.userToken,
        ]) { status, json in
            let sdk = Wonderchat.shared
            guard status == 200, !sdk.isChatOpen, conversation == sdk.conversation,
                  let count = json?["unreadCount"] as? Int else { return }
            sdk.unreadCount = max(0, count)
        }
    }

    private func scheduleUnreadPolling() {
        stopUnreadPolling()
        guard unreadPollingInterval > 0, !isChatOpen, chatbotId != nil,
              UIApplication.shared.applicationState != .background else { return }
        let timer = Timer(timeInterval: unreadPollingInterval, repeats: true) { _ in
            Task { @MainActor in Wonderchat.shared.refreshUnread() }
        }
        timer.tolerance = unreadPollingInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopUnreadPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @discardableResult
    private func post(
        _ path: String,
        body: [String: Any],
        completion: @escaping @MainActor (Int, [String: Any]?) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in completion(status, json) }
        }
        task.resume()
        return task
    }

    // MARK: Helpers

    private func persist() {
        guard let chatbotId else { return }
        Storage.save(
            chatbotId: chatbotId,
            conversation: conversation,
            registeredKey: registeredKey,
            clearHistoryOnNextLoad: clearHistoryOnNextLoad
        )
    }

    private func removeDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { Wonderchat.isWonderchatNotification($0.request.content.userInfo) }
                .map(\.request.identifier)
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = (scenes.filter { $0.activationState == .foregroundActive } + scenes).flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

struct Conversation: Equatable {
    let chatlogId: String
    let userToken: String
}

/// Conversation persistence in UserDefaults, one entry per chatbot.
enum Storage {
    private static func key(_ chatbotId: String) -> String { "com.wonderchat.sdk.\(chatbotId)" }

    static func load(chatbotId: String) -> (conversation: Conversation?, registeredKey: String?, clearHistoryOnNextLoad: Bool) {
        let stored = UserDefaults.standard.dictionary(forKey: key(chatbotId)) ?? [:]
        var conversation: Conversation?
        if let chatlogId = stored["chatlogId"] as? String, let userToken = stored["userToken"] as? String {
            conversation = Conversation(chatlogId: chatlogId, userToken: userToken)
        }
        return (conversation, stored["registeredKey"] as? String, stored["clearHistory"] as? Bool ?? false)
    }

    static func save(chatbotId: String, conversation: Conversation?, registeredKey: String?, clearHistoryOnNextLoad: Bool) {
        var stored: [String: Any] = [:]
        if let conversation {
            stored["chatlogId"] = conversation.chatlogId
            stored["userToken"] = conversation.userToken
        }
        if let registeredKey { stored["registeredKey"] = registeredKey }
        if clearHistoryOnNextLoad { stored["clearHistory"] = true }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(chatbotId))
        } else {
            UserDefaults.standard.set(stored, forKey: key(chatbotId))
        }
    }
}
