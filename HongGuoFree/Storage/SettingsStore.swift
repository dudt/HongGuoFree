// 持久化：设置、收藏、历史、播放进度
import Foundation
import SwiftUI
import Combine

// MARK: - 设置

final class SettingsStore: ObservableObject {
    private enum Key {
        static let autoplayNext = "app.autoplayNext"
        static let loopEpisode = "app.loopEpisode"
        static let rememberProgress = "app.rememberProgress"
        static let playbackRate = "app.playbackRate"
        static let preferQuality = "app.preferQuality"
        static let resolverBaseURL = "app.resolverBaseURL"
        static let resolverToken = "app.resolverToken"
        static let directMode = "app.directMode"
    }

    private let defaults = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    @Published var autoplayNext: Bool
    @Published var loopEpisode: Bool
    @Published var rememberProgress: Bool
    @Published var playbackRate: Double
    @Published var preferQuality: String

    /// 自建解析服务地址（server/hongguo-server.mjs）
    @Published var resolverBaseURL: String
    /// 服务端 ACCESS_TOKEN（可选）
    @Published var resolverToken: String

    /// 直连模式：视频流走 CDN，服务器只给密钥（省 146 倍带宽）
    @Published var directMode: Bool

    /// 组装好的解析服务配置
    var resolverConfig: ResolverConfig {
        ResolverConfig(baseURL: resolverBaseURL, token: resolverToken)
    }

    /// 是否已配置解析服务
    var hasResolver: Bool { resolverConfig.isConfigured }

    init() {
        defaults.register(defaults: [
            Key.autoplayNext: true,
            Key.loopEpisode: false,
            Key.rememberProgress: true,
            Key.playbackRate: 1.0,
            Key.preferQuality: "自动",
            Key.resolverBaseURL: "",
            Key.resolverToken: "",
            Key.directMode: true
        ])

        let storedRate = defaults.double(forKey: Key.playbackRate)
        autoplayNext = defaults.bool(forKey: Key.autoplayNext)
        loopEpisode = defaults.bool(forKey: Key.loopEpisode)
        rememberProgress = defaults.bool(forKey: Key.rememberProgress)
        playbackRate = storedRate == 0 ? 1.0 : storedRate
        preferQuality = defaults.string(forKey: Key.preferQuality) ?? "自动"
        resolverBaseURL = defaults.string(forKey: Key.resolverBaseURL) ?? ""
        resolverToken = defaults.string(forKey: Key.resolverToken) ?? ""
        directMode = defaults.object(forKey: Key.directMode) as? Bool ?? true

        bindPersistence()
    }

    /// 任何设置变化都写回 UserDefaults（避免给 @Published 加 didSet）
    private func bindPersistence() {
        $autoplayNext
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.autoplayNext) }
            .store(in: &bag)
        $loopEpisode
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.loopEpisode) }
            .store(in: &bag)
        $rememberProgress
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.rememberProgress) }
            .store(in: &bag)
        $playbackRate
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.playbackRate) }
            .store(in: &bag)
        $preferQuality
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.preferQuality) }
            .store(in: &bag)
        $resolverBaseURL
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.resolverBaseURL) }
            .store(in: &bag)
        $resolverToken
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.resolverToken) }
            .store(in: &bag)
        $directMode
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.directMode) }
            .store(in: &bag)
    }
}
