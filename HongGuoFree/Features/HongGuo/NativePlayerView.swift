// 原生播放器（AVPlayerViewController）
//
// 为什么用系统播放器：
//   自己拼手势层容易互相抢触摸（上一版 LongPressBridge 覆盖在最上层，
//   把 tap/drag 全拦掉了）。AVPlayerViewController 是苹果官方组件，
//   自带完整的控制层、手势、AirPlay、画中画、字幕、倍速，
//   稳定性和体验都是系统级的。
//
// 弹幕怎么叠：
//   AVPlayerViewController.contentOverlayView 位于「视频之上、控制层之下」，
//   把弹幕 layer 加进去即可 —— 控制层出现时自动盖住弹幕，符合原生行为。
//   弹幕 view 设 isUserInteractionEnabled = false，不干扰系统手势。
//
// 弹幕时间同步：
//   弹幕层自己监听 AVPlayer 的 periodicTimeObserver，
//   不依赖 SwiftUI 状态刷新，性能最好。
import SwiftUI
import AVKit
import AVFoundation

// MARK: - SwiftUI 包装

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 弹幕轨道（装载后不变）
    let danmakuItems: [ScheduledDanmaku]
    let danmakuSettings: DanmakuSettings
    /// 是否显示系统控制层
    var showsControls: Bool = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = showsControls
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.updatesNowPlayingInfoCenter = true

        // 弹幕层挂到 contentOverlayView
        let dm = DanmakuPlayerOverlay()
        dm.isUserInteractionEnabled = false
        dm.translatesAutoresizingMaskIntoConstraints = false
        if let host = vc.contentOverlayView {
            host.addSubview(dm)
            NSLayoutConstraint.activate([
                dm.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                dm.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                dm.topAnchor.constraint(equalTo: host.topAnchor),
                dm.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        context.coordinator.overlay = dm
        context.coordinator.attach(to: player)
        dm.apply(items: danmakuItems, settings: danmakuSettings)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        if vc.showsPlaybackControls != showsControls {
            vc.showsPlaybackControls = showsControls
        }
        context.coordinator.overlay?.apply(items: danmakuItems,
                                           settings: danmakuSettings)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIViewController(_ vc: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.detach()
        coordinator.overlay?.removeFromSuperview()
    }

    final class Coordinator {
        weak var overlay: DanmakuPlayerOverlay?
        private var timeObserver: Any?
        private weak var player: AVPlayer?

        func attach(to player: AVPlayer) {
            detach()
            self.player = player
            // 弹幕自己跟时间，不经过 SwiftUI
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                queue: .main
            ) { [weak self] t in
                let secs = t.seconds
                guard secs.isFinite else { return }
                self?.overlay?.tick(time: secs)
            }
        }

        func detach() {
            if let o = timeObserver, let p = player {
                p.removeTimeObserver(o)
            }
            timeObserver = nil
        }
    }
}

// MARK: - 弹幕叠加层（纯 UIKit，零 SwiftUI 刷新）

final class DanmakuPlayerOverlay: UIView {

    private var settings = DanmakuSettings()
    private var items: [ScheduledDanmaku] = []
    private var nextIndex = 0
    private var live: [String: CALayer] = [:]
    private var currentTime: Double = 0
    private var lastScheduledBase: Double = -1
    private let lookahead = 3.0
    private let container = CALayer()
    private let imageCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 800
        return c
    }()
    private var ticker: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        layer.addSublayer(container)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.schedule()
        }
        if let t = ticker { RunLoop.main.add(t, forMode: .common) }
    }

    deinit {
        ticker?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
    }

    // MARK: 对外

    func apply(items new: [ScheduledDanmaku], settings s: DanmakuSettings) {
        let itemsChanged = new.count != items.count || new.first?.id != items.first?.id
        let settingsChanged = s != settings
        guard itemsChanged || settingsChanged else { return }

        items = new
        settings = s
        if settingsChanged { imageCache.removeAllObjects() }
        clearLive()
        nextIndex = indexFor(time: currentTime)
        schedule()
    }

    func tick(time: Double) {
        currentTime = time
        // 大跨度跳转（拖动进度）→ 重建
        if abs(time - lastScheduledBase) > 1.5 {
            clearLive()
            nextIndex = indexFor(time: time)
            schedule()
        }
    }

    // MARK: 调度

    private func indexFor(time t: Double) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].startSec < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func schedule() {
        guard !items.isEmpty, bounds.width > 1 else { return }
        let now = currentTime
        lastScheduledBase = now
        let until = now + lookahead

        while nextIndex < items.count {
            let d = items[nextIndex]
            if d.startSec > until { break }
            nextIndex += 1
            if d.startSec < now - 0.5 { continue }
            emit(d, now: now)
        }

        let expire = now - settings.duration - 1.5
        for (id, l) in live {
            if (l.value(forKeyPath: "startSec") as? Double ?? 0) < expire {
                l.removeFromSuperlayer()
                live.removeValue(forKey: id)
            }
        }
    }

    private func emit(_ d: ScheduledDanmaku, now: Double) {
        guard let cg = image(for: d.text) else { return }
        let scale = UIScreen.main.scale
        let w = CGFloat(cg.width) / scale
        let h = CGFloat(cg.height) / scale

        let lanes = laneCount()
        let lane = min(d.lane, max(lanes - 1, 0))
        let laneH = CGFloat(settings.fontSize) * 1.85
        let y = CGFloat(settings.topInset) + CGFloat(lane) * laneH

        let l = CALayer()
        l.contents = cg
        l.contentsScale = scale
        l.frame = CGRect(x: 0, y: 0, width: w, height: h)
        l.opacity = Float(settings.opacity)
        l.setValue(d.startSec, forKeyPath: "startSec")
        container.addSublayer(l)

        let fromX = bounds.width + w / 2 + 4
        let toX = -w / 2 - 4

        let anim = CABasicAnimation(keyPath: "position")
        anim.fromValue = CGPoint(x: fromX, y: y + h / 2)
        anim.toValue = CGPoint(x: toX, y: y + h / 2)
        anim.duration = settings.duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false

        let delay = max(0, d.startSec - now)
        if delay > 0.02 {
            anim.beginTime = container.convertTime(
                CACurrentMediaTime() + delay, from: nil)
        }

        l.position = CGPoint(x: toX, y: y + h / 2)
        l.add(anim, forKey: "fly")
        live[d.id] = l
    }

    private func clearLive() {
        for (_, l) in live { l.removeFromSuperlayer() }
        live.removeAll()
    }

    private func laneCount() -> Int {
        let usable = Double(bounds.height) * settings.areaRatio - settings.topInset
        let laneH = settings.fontSize * 1.85
        return max(1, min(14, Int(usable / laneH)))
    }

    private func image(for text: String) -> CGImage? {
        let key = "\(Int(settings.fontSize))|\(settings.stroke ? 1 : 0)|\(text)" as NSString
        if let c = imageCache.object(forKey: key) { return c }

        let font = UIFont.systemFont(ofSize: CGFloat(settings.fontSize), weight: .medium)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        if settings.stroke {
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -3.2
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        guard size.width > 0, size.height > 0 else { return nil }

        let pad: CGFloat = 3
        let canvas = CGSize(width: ceil(size.width) + pad * 2,
                            height: ceil(size.height) + pad * 2)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            str.draw(at: CGPoint(x: pad, y: pad))
        }
        guard let cg = img.cgImage else { return nil }
        imageCache.setObject(cg, forKey: key)
        return cg
    }
}
