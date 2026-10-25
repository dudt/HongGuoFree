// 播放引擎：AVPlayer + 无广告 + 自动下一集 + 进度记忆
import Foundation
import AVFoundation
import Combine

final class PlayerEngine: ObservableObject {
    @Published private(set) var currentDrama: Drama?
    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var source: PlaySource?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var failedMessage: String?
    @Published var isFullScreen = false
    @Published var isScrubbing = false

    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var stallingObserver: NSObjectProtocol?

    private var episodes: [Episode] = []
    private var dramaID: String?
    private var resumePosition: Double = 0
    private var didApplyInitialSeek = false
    private var lastProgressSave = Date.distantPast

    private let store: AppStore
    private let settings: SettingsStore

    init(store: AppStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = true
        installTimeObserver()
        installEndObserver()
        installStallingObserver()
    }

    var hasActiveItem: Bool { currentDrama != nil }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var episodeTitle: String { currentEpisode?.displayTitle ?? "未播放" }

    var upNext: Episode? {
        guard let currentEpisode else { return nil }
        return episodes.first { $0.index == currentEpisode.index + 1 }
    }

    // MARK: - 播放控制

    func play(drama: Drama, episode: Episode) {
        episodes = drama.episodes.sorted { $0.index < $1.index }
        dramaID = drama.id
        currentDrama = drama
        start(episode: episode)
    }

    func select(episode: Episode) {
        guard currentDrama != nil else { return }
        start(episode: episode)
    }

    func playNext() {
        guard let upNext else { return }
        start(episode: upNext)
    }

    private func start(episode: Episode) {
        guard let source = episode.bestSource, let url = source.resolvedURL else {
            failedMessage = "这一集没有可用的播放地址。"
            return
        }

        currentEpisode = episode
        self.source = source
        failedMessage = nil
        duration = episode.duration ?? 0
        currentTime = 0
        isBuffering = true
        didApplyInitialSeek = false

        if settings.rememberProgress,
           let record = store.library.record(for: currentDrama?.id ?? ""),
           record.episodeID == episode.id {
            resumePosition = record.position
        } else {
            resumePosition = 0
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: item)
        bind(item: item)
        player.play()
        player.rate = Float(max(0.5, settings.playbackRate))
        isPlaying = true

        if let dramaID {
            store.library.touchHistory(dramaID)
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentItem == nil, let episode = currentEpisode, let drama = currentDrama {
                play(drama: drama, episode: episode)
                return
            }
            player.play()
            player.rate = Float(max(0.5, settings.playbackRate))
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = max(0, min(seconds, upper))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Double) {
        player.rate = Float(rate)
        if rate > 0 { isPlaying = true }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentDrama = nil
        currentEpisode = nil
        source = nil
        currentTime = 0
        duration = 0
        isFullScreen = false
    }

    func dismissError() { failedMessage = nil }

    // MARK: - 观察

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            guard !self.isScrubbing else { return }
            let seconds = time.seconds
            if seconds.isFinite { self.currentTime = seconds }
            let total = self.player.currentItem?.duration.seconds ?? 0
            if total.isFinite, total > 0 { self.duration = total }
            self.persistProgress()
        }
    }

    private func installEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            // 播完这一集就清掉进度，避免“继续观看”停在 0%
            self.clearRecord()
            if self.settings.loopEpisode {
                self.seek(to: 0)
                self.player.play()
                self.isPlaying = true
            } else if self.settings.autoplayNext {
                self.playNext()
            }
        }
    }

    private func installStallingObserver() {
        stallingObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isBuffering = true
        }
    }

    private func bind(item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.failedMessage = nil
                    if !self.didApplyInitialSeek {
                        self.didApplyInitialSeek = true
                        if self.resumePosition > 1 {
                            self.seek(to: self.resumePosition)
                        }
                    }
                    self.player.play()
                    self.player.rate = Float(max(0.5, self.settings.playbackRate))
                    self.isPlaying = true
                case .failed:
                    self.isBuffering = false
                    self.isPlaying = false
                    self.failedMessage = item.error?.localizedDescription ?? "视频加载失败，换一集试试。"
                default:
                    break
                }
            }
    }

    private func persistProgress() {
        guard settings.rememberProgress, !isScrubbing else { return }
        // 每 5 秒落盘一次，避免每帧写文件
        guard Date().timeIntervalSince(lastProgressSave) > 5 else { return }
        lastProgressSave = Date()
        saveRecord()
    }

    private func saveRecord() {
        guard let dramaID, let episode = currentEpisode else { return }
        let total = duration > 0 ? duration : (episode.duration ?? 0)
        guard total > 0 else { return }
        let record = PlaybackRecord(dramaID: dramaID,
                                    episodeID: episode.id,
                                    episodeIndex: episode.index,
                                    position: currentTime,
                                    duration: total,
                                    updatedAt: Date())
        store.library.save(record)
    }

    private func clearRecord() {
        guard let dramaID else { return }
        store.library.clearProgress(for: dramaID)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let stallingObserver {
            NotificationCenter.default.removeObserver(stallingObserver)
        }
    }
}
