import SwiftUI
import Wonderchat

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: Home: floating Support button

struct HomeView: View {
    var body: some View {
        NavigationView {
            List {
                Section("Today") {
                    ForEach(["Morning run", "Team standup", "Ship the release"], id: \.self) { item in
                        Label(item, systemImage: "circle")
                    }
                }
            }
            .navigationTitle("Home")
        }
        .navigationViewStyle(.stack)
        .overlay(alignment: .bottomTrailing) {
            FloatingSupportButton()
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
    }
}

struct FloatingSupportButton: View {
    @ObservedObject private var wonderchat = Wonderchat.shared

    var body: some View {
        Button { Wonderchat.openChat() } label: {
            Label("Support", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
                .padding(.horizontal, 20)
                .frame(minHeight: 52)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .overlay(alignment: .topTrailing) {
            if wonderchat.unreadCount > 0 {
                UnreadBadge(count: wonderchat.unreadCount)
                    .offset(x: 6, y: -6)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("floatingSupport")
        .accessibilityValue(Text("\(wonderchat.unreadCount) unread messages"))
    }
}

// MARK: Settings: Support row

struct SettingsView: View {
    @ObservedObject private var wonderchat = Wonderchat.shared

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button { Wonderchat.openChat() } label: {
                        HStack {
                            Label("Support", systemImage: "bubble.left.and.bubble.right")
                                .foregroundColor(.primary)
                            Spacer()
                            if wonderchat.unreadCount > 0 {
                                UnreadBadge(count: wonderchat.unreadCount)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                    .accessibilityIdentifier("settingsSupport")
                    .accessibilityValue(Text("\(wonderchat.unreadCount) unread messages"))
                }
                Section {
                    Button("Sign Out", role: .destructive) { Wonderchat.reset() }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Color.red))
    }
}
