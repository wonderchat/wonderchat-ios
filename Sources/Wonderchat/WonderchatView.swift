import SwiftUI

/// The chat as a SwiftUI view, for a dedicated Support tab or your own sheet.
///
/// ```swift
/// TabView {
///     WonderchatView().tabItem { Label("Support", systemImage: "bubble.left") }
/// }
/// ```
///
/// To open the chat from a button, prefer `Wonderchat.openChat()`, which
/// presents a native page sheet.
public struct WonderchatView: UIViewControllerRepresentable {
    private let onClose: (() -> Void)?

    /// - Parameter onClose: called when the user taps the chat's close
    ///   button. Use it to dismiss your sheet or switch tabs.
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public func makeUIViewController(context: Context) -> WonderchatViewController {
        let controller = WonderchatViewController()
        controller.onClose = onClose
        return controller
    }

    public func updateUIViewController(_ controller: WonderchatViewController, context: Context) {
        controller.onClose = onClose
    }
}
