// 应用入口与依赖装配
import SwiftUI
import UIKit

@main
struct HongGuoFreeApp: App {
    @StateObject private var container = AppContainer()

    init() {
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container.store)
                .environmentObject(container.settings)
                .environmentObject(container.player)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}

/// 统一创建并串联 AppStore / SettingsStore / PlayerEngine
final class AppContainer: ObservableObject {
    let store: AppStore
    let settings: SettingsStore
    let player: PlayerEngine

    init() {
        let store = AppStore()
        let settings = SettingsStore()
        store.attach(settings: settings)
        self.store = store
        self.settings = settings
        self.player = PlayerEngine(store: store, settings: settings)
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            FeedView()
                .withMiniPlayer()
                .tabItem { Label("推荐", systemImage: "play.rectangle.on.rectangle") }

            SearchView()
                .withMiniPlayer()
                .tabItem { Label("发现", systemImage: "magnifyingglass") }

            LibraryView()
                .withMiniPlayer()
                .tabItem { Label("追剧", systemImage: "bookmark.fill") }

            SettingsView()
                .withMiniPlayer()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(Palette.accent)
        .fullScreenCover(isPresented: Binding(
            get: { player.isFullScreen },
            set: { player.isFullScreen = $0 }
        )) {
            PlayerScreen()
                .environmentObject(player)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .task {
            await store.reloadAll()
        }
    }
}

struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: PlayerEngine

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.hasActiveItem {
                MiniPlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.hasActiveItem)
    }
}

extension View {
    func withMiniPlayer() -> some View {
        modifier(MiniPlayerInset())
    }
}

enum Appearance {
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Palette.background)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Palette.surface)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
