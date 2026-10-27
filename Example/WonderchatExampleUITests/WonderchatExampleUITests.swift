import XCTest

struct E2EError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// End-to-end check against a running Wonderchat server, driven by
/// scripts/verify.sh. The harness (scripts/harness_server.py) inserts the
/// teammate reply and sends the simulated push, since a UI test cannot reach
/// the database or `simctl` itself.
///
/// Test-runner environment (set as TEST_RUNNER_<name> for xcodebuild):
/// WONDERCHAT_BASE_URL, WONDERCHAT_CHATBOT_ID, WONDERCHAT_HARNESS_URL.
final class WonderchatExampleUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["WONDERCHAT_BASE_URL"] = env["WONDERCHAT_BASE_URL"] ?? "http://localhost:3100"
        app.launchEnvironment["WONDERCHAT_CHATBOT_ID"] = env["WONDERCHAT_CHATBOT_ID"] ?? "mobile-e2e-bot"
    }

    func testSetupCheckUnreadBadgeAndPush() throws {
        app.launchEnvironment["WONDERCHAT_SETUP_CHECK"] = "1"
        app.launchEnvironment["WONDERCHAT_REQUEST_PUSH_PERMISSION"] = "1"
        app.launch()
        allowNotificationsIfAsked()

        // 1. The setup message is sent and the bot answers.
        let chat = app.webViews["wonderchat.chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "Chat sheet did not open")
        let hello = chat.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hello from setup")).firstMatch
        XCTAssertTrue(hello.waitForExistence(timeout: 60), "\"Hello from setup\" never appeared in the chat")
        let reply = try waitForBotReply(in: chat, timeout: 120)
        print("WONDERCHAT_E2E bot reply: \(reply.prefix(120))")
        attachScreenshot("chat-with-reply")

        // 2. Close the chat (page close button when present, else swipe the sheet down).
        let closedWith = closeChat(chat)
        print("WONDERCHAT_E2E closed chat via: \(closedWith)")
        XCTAssertTrue(waitForDisappearance(of: chat, timeout: 10), "Chat did not close")

        // 3. A teammate reply shows the unread badge once the app refreshes.
        try harness("agent-reply")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let floating = app.buttons["floatingSupport"]
        XCTAssertTrue(waitForValue(of: floating, "1 unread messages", timeout: 30),
                      "Unread badge did not appear on the floating button (value: \(floating.value ?? "nil"))")
        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons["settingsSupport"]
        XCTAssertTrue(waitForValue(of: row, "1 unread messages", timeout: 5),
                      "Unread badge missing on the Settings Support row (value: \(row.value ?? "nil"))")
        attachScreenshot("unread-badge")

        // 4. Tapping a Wonderchat push opens the chat.
        XCUIDevice.shared.press(.home)
        sleep(1)
        try harness("push")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Reply from the team")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "Push banner did not appear")
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App did not come to the foreground")
        let reopened = app.webViews["wonderchat.chat"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 15), "Tapping the push did not open the chat")
        let teamReply = reopened.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reply from the team")).firstMatch
        XCTAssertTrue(teamReply.waitForExistence(timeout: 30), "The teammate reply is not shown in the chat")
        attachScreenshot("opened-from-push")

        // 5. Having read the reply, the badge stays clear after closing.
        print("WONDERCHAT_E2E closed chat again via: \(closeChat(reopened))")
        XCTAssertTrue(waitForDisappearance(of: reopened, timeout: 10), "Chat did not close")
        sleep(3)
        XCTAssertEqual(row.value as? String, "0 unread messages", "Badge came back after reading the reply")
    }

    // MARK: Helpers

    private func allowNotificationsIfAsked() {
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
    }

    /// Waits for text that appears after "Hello from setup" and wasn't on the
    /// page when the message first showed up.
    private func waitForBotReply(in chat: XCUIElement, timeout: TimeInterval) throws -> String {
        let baseline = Set(textsAfterHello(in: chat))
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: String?
        var stableSince = Date()
        while Date() < deadline {
            let fresh = textsAfterHello(in: chat).filter { !baseline.contains($0) && $0.count >= 8 }
            let candidate = fresh.joined(separator: " ")
            if !candidate.isEmpty {
                // Let streaming settle so the screenshot shows the full answer.
                if candidate == lastSeen, Date().timeIntervalSince(stableSince) > 3 { return candidate }
                if candidate != lastSeen { lastSeen = candidate; stableSince = Date() }
            }
            sleep(1)
        }
        if let lastSeen { return lastSeen }
        attachScreenshot("no-bot-reply")
        throw E2EError(message: "The bot did not reply within \(Int(timeout))s")
    }

    private func textsAfterHello(in chat: XCUIElement) -> [String] {
        let labels = chat.staticTexts.allElementsBoundByIndex.map(\.label)
        guard let index = labels.lastIndex(where: { $0.contains("Hello from setup") }) else { return [] }
        return labels[(index + 1)...].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func closeChat(_ chat: XCUIElement) -> String {
        let close = chat.buttons.matching(NSPredicate(format: "label ==[c] 'close' OR label ==[c] 'close chat'")).firstMatch
        if close.exists, close.isHittable {
            close.tap()
            if waitForDisappearance(of: chat, timeout: 5) { return "page close button (closeChat)" }
        }
        let top = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)).withOffset(CGVector(dx: 0, dy: -6))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        return "swipe down on the sheet grabber"
    }

    private func waitForValue(of element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool {
        let match = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        return XCTWaiter.wait(for: [match], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func harness(_ action: String) throws {
        let base = env["WONDERCHAT_HARNESS_URL"] ?? "http://127.0.0.1:8765"
        var request = URLRequest(url: URL(string: "\(base)/\(action)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let done = expectation(description: "harness \(action)")
        var status = 0
        var body = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data.flatMap { String(data: $0, encoding: .utf8) } ?? (error?.localizedDescription ?? "")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 70)
        print("WONDERCHAT_E2E harness \(action): \(status) \(body)")
        XCTAssertEqual(status, 200, "Harness \(action) failed: \(body)")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
