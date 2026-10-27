import SwiftUI
import UIKit
import UserNotifications
import Wonderchat

/// Launch environment (Xcode scheme or `simctl launch`):
/// - `WONDERCHAT_BASE_URL` (default http://localhost:3100)
/// - `WONDERCHAT_CHATBOT_ID` (default mobile-e2e-bot)
/// - `WONDERCHAT_SETUP_CHECK=1` registers a fake push token, opens the chat and
///   sends "Hello from setup".
/// - `WONDERCHAT_REQUEST_PUSH_PERMISSION=1` asks for notification permission
///   at launch (stands in for the app's own consent flow).
enum DemoEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let baseURL = URL(string: values["WONDERCHAT_BASE_URL"] ?? "") ?? URL(string: "http://localhost:3100")!
    static let chatbotId = values["WONDERCHAT_CHATBOT_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "mobile-e2e-bot"
    static let isSetupCheck = values["WONDERCHAT_SETUP_CHECK"] == "1"
    static let requestsPushPermission = values["WONDERCHAT_REQUEST_PUSH_PERMISSION"] == "1"
    @MainActor static var didRunSetupCheck = false

    /// 32 bytes 0x00...0x1f, hex "000102...1f".
    static let fakePushToken = Data((0..<32).map { UInt8($0) })
}

@main
struct WonderchatExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Wonderchat.configure(chatbotId: DemoEnvironment.chatbotId, baseURL: DemoEnvironment.baseURL)
        Wonderchat.identify(name: "Demo User", custom: ["plan": "demo"])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear(perform: runSetupCheckIfRequested)
        }
    }

    private func runSetupCheckIfRequested() {
        guard DemoEnvironment.isSetupCheck, !DemoEnvironment.didRunSetupCheck else { return }
        DemoEnvironment.didRunSetupCheck = true
        Wonderchat.setPushToken(DemoEnvironment.fakePushToken)
        Wonderchat.openChat()
        Wonderchat.sendMessage("Hello from setup")
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if DemoEnvironment.requestsPushPermission {
            requestPushPermission()
        } else {
            registerIfAuthorized()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // The setup check binds its fixed fake token instead.
        guard !DemoEnvironment.isSetupCheck else { return }
        Wonderchat.setPushToken(deviceToken)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if Wonderchat.handleNotification(notification.request.content.userInfo, openChat: false) {
            return Wonderchat.isChatOpen ? [] : [.banner, .sound]
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if Wonderchat.handleNotification(response.notification.request.content.userInfo) { return }
        // The app's own notification taps are handled here.
    }

    func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private func registerIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
