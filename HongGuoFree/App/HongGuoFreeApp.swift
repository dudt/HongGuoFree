// 应用入口与依赖装配
import SwiftUI
import UIKit

@main
@MainActor
struct HongGuoFreeApp: App {
    @StateObject private var container = AppContainer()

    init() {
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container.settings)
                .environmentObject(container.feed)
                .environmentObject(container.library)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}

/// 依赖容器。HGFeedStore / HGLibraryStore 都是 @MainActor 隔离的，
/// 所以整个容器放到主线程上下文（Xcode 16 并发检查要求）。
@MainActor
final class AppContainer: ObservableObject {
    let settings: SettingsStore
    let feed: HGFeedStore
    let library: HGLibraryStore

    init() {
        self.settings = SettingsStore()
        self.feed = HGFeedStore()
        self.library = HGLibraryStore()
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var feed: HGFeedStore
    @EnvironmentObject private var library: HGLibraryStore

    var body: some View {
        TabView {
            FeedView()
                .tabItem { Label("首页", systemImage: "flame.fill") }

            LibraryView()
                .tabItem { Label("追剧", systemImage: "bookmark.fill") }

            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(Palette.accent)
    }
}

enum Appearance {
    @MainActor
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
