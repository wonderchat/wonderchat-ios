# Wonderchat for iOS

Add Wonderchat's AI support chat to your iOS app. The agent answers from your
docs, hands the conversation to your team when it is unsure, and your team's
replies reach users as push notifications.

Requires iOS 15+. No dependencies.

The fastest setup is the prompt in your Wonderchat dashboard
(**Installation → Mobile app**): paste it into your coding agent.

## Install

Swift Package Manager: add `https://github.com/wonderchat/wonderchat-ios`
(Up to Next Major Version), product `Wonderchat`.

CocoaPods: `pod 'Wonderchat'`

## Configure

```swift
import Wonderchat

Wonderchat.configure(chatbotId: "YOUR_CHATBOT_ID")
```

## Open the chat

```swift
Wonderchat.present()                              // UIKit
.sheet(isPresented: $showSupport) { WonderchatView() } // SwiftUI
```

## Identify users

```swift
Wonderchat.identify(email: user.email, name: user.name, custom: ["userId": user.id])
```

## Push notifications

1. Add the Push Notifications capability to your target.
2. Forward the device token:

   ```swift
   func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
       Wonderchat.setPushToken(token)
   }
   ```

3. Open the chat when a notification is tapped:

   ```swift
   Wonderchat.handleNotification(response.notification.request.content.userInfo)
   ```

4. In the dashboard, add your APNs key (.p8), Key ID, Team ID and bundle ID.

The SDK never asks for notification permission. Use your app's own flow.

## License

MIT
