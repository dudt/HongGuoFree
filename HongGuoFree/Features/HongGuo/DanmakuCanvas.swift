// 弹幕画布
//
// 直接绑定 AVPlayer，自己监听时间，不经过 SwiftUI 状态刷新。
// 每条弹幕 = 一个 CALayer + 一条 CABasicAnimation，
// 动画提交后由 Core Animation 渲染进程插值，主线程零参与。
import SwiftUI
import AVFoundation

struct DanmakuCanvas: UIViewRepresentable {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer

    func makeUIView(context: Context) -> DanmakuCanvasView {
        let v = DanmakuCanvasView()
        v.isUserInteractionEnabled = false
        v.attach(player: player)
        v.apply(items: engine.scheduled, settings: engine.settings)
        return v
    }

    func updateUIView(_ v: DanmakuCanvasView, context: Context) {
        v.attach(player: player)
        v.apply(items: engine.scheduled, settings: engine.settings)
    }

    static func dismantleUIView(_ v: DanmakuCanvasView, coordinator: ()) {
        v.detach()
    }
}

// MARK: - 实现

final class DanmakuCanvasView: UIView {

    private var settings = DanmakuSettings()
    private var items: [ScheduledDanmaku] = []
    private var nextIndex = 0
    private var live: [String: CALayer] = [:]
    private var currentTime: Double = 0
    private var lastScheduledBase: Double = -1
    private let lookahead = 3.0

    private let container = CALayer()
    private var ticker: Timer?
    private weak var player: AVPlayer?
    private var timeObserver: Any?

    private let imageCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 800
        return c
    }()

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
        detach()
        ticker?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
    }

    // MARK: 绑定播放器

    func attach(player: AVPlayer) {
        guard self.player !== player else { return }
        detach()
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            self.currentTime = s
            if abs(s - self.lastScheduledBase) > 1.5 {
                // 大跨度跳转 → 重建
                self.clearLive()
                self.nextIndex = self.indexFor(time: s)
                self.schedule()
            }
        }
    }

    func detach() {
        if let o = timeObserver, let p = player {
            p.removeTimeObserver(o)
        }
        timeObserver = nil
    }

    // MARK: 数据

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
        guard settings.enabled, !items.isEmpty, bounds.width > 1 else { return }
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
