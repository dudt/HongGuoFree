// 原生弹幕渲染层
//
// 为什么能像原生一样流畅：
//   每条弹幕 = 一个 CALayer + 一条 CABasicAnimation。
//   动画一旦提交给 Core Animation，后续每一帧的位移插值都由渲染服务进程
//   完成，主线程零参与。所以 300 条弹幕和 3 条弹幕的 CPU 开销几乎一样。
//
// 旧版（SwiftUI Canvas + TimelineView）的问题：
//   每帧都要 resolve Text、计算布局、画 5 次描边（1 主 + 4 阴影），
//   全部在主线程，弹幕一多就掉到 20fps。
//
// 时间同步：
//   用「预排程」而不是「逐帧推位置」。每个 tick 往前看 3 秒，
//   把即将出现的弹幕用 beginTime = 未来某个时刻 提交给 CA，
//   所以起始时间精确到毫秒，与 tick 频率无关。
import UIKit
import SwiftUI

// MARK: - UIViewRepresentable

struct DanmakuLayerView: UIViewRepresentable {
    @ObservedObject var engine: DanmakuEngine
    /// 播放器当前时间（秒）
    let playerTime: Double
    /// 是否暂停
    let isPaused: Bool

    func makeUIView(context: Context) -> DanmakuRenderer {
        let v = DanmakuRenderer()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: DanmakuRenderer, context: Context) {
        v.apply(settings: engine.settings)
        v.apply(items: engine.scheduled)
        v.apply(time: playerTime, paused: isPaused)
    }
}

// MARK: - 渲染器

final class DanmakuRenderer: UIView {

    // MARK: 状态

    private var settings = DanmakuSettings()
    private var items: [ScheduledDanmaku] = []
    private var nextIndex = 0
    private var live: [String: CALayer] = [:]

    private var playing = true
    private var currentTime: Double = 0
    private var lastAppliedTime: Double = -1
    private var lastSettings: DanmakuSettings?

    /// 预排程窗口（秒）
    private let lookahead = 3.0
    /// 调度器频率（只用来增删 layer，动画本身由 CA 驱动）
    private var ticker: Timer?
    /// 独立的容器 layer：暂停/恢复只作用于它，不影响 view 自身
    private let container = CALayer()

    private let imageCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 600
        return c
    }()

    // MARK: 生命周期

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.masksToBounds = true
        container.frame = bounds
        container.masksToBounds = true
        layer.addSublayer(container)
        // 整个容器一起暂停/恢复，子 layer 的动画会跟着冻结
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        ticker?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTicker()
        } else {
            startTicker()
        }
    }

    @objc private func didEnterBackground() {
        stopTicker()
        clearLive()
    }

    @objc private func willEnterForeground() {
        // 回前台后所有 CA 动画都失效了，按当前进度重建
        clearLive()
        nextIndex = indexFor(time: currentTime)
        startTicker()
        schedule()
    }

    // MARK: 对外接口

    func apply(settings new: DanmakuSettings) {
        guard new != lastSettings else { return }
        lastSettings = new
        settings = new
        imageCache.removeAllObjects()
        rebuildAll()
    }

    func apply(items new: [ScheduledDanmaku]) {
        guard new.count != items.count || new.first?.id != items.first?.id else { return }
        items = new
        clearLive()
        nextIndex = indexFor(time: currentTime)
        schedule()
    }

    func apply(time t: Double, paused: Bool) {
        let timeChanged = abs(t - lastAppliedTime) > 0.05
        lastAppliedTime = t
        currentTime = t

        // 暂停状态切换：playing 应与 !paused 一致
        let shouldPlay = !paused
        if shouldPlay != playing {
            playing = shouldPlay
            if playing {
                container.speed = 1.0
                container.timeOffset = 0
                container.beginTime = 0
                startTicker()
                // 恢复后所有动画时间基准已变，按当前进度重建
                clearLive()
                nextIndex = indexFor(time: t)
                schedule()
            } else {
                let pausedAt = container.convertTime(CACurrentMediaTime(), from: nil)
                container.speed = 0
                container.timeOffset = pausedAt
                stopTicker()
            }
        }

        // 大跨度跳转（拖动进度条）：重建
        if timeChanged, abs(t - lastScheduledBase) > 1.2 {
            clearLive()
            nextIndex = indexFor(time: t)
            schedule()
        } else if playing, timeChanged {
            schedule()
        }
    }

    // MARK: 调度

    private var lastScheduledBase: Double = -1

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.schedule()
        }
        if let t = ticker { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func indexFor(time t: Double) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].startSec < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func schedule() {
        guard playing, !items.isEmpty, bounds.width > 1 else { return }
        let now = currentTime
        lastScheduledBase = now
        let until = now + lookahead

        // 补上窗口内的新弹幕
        while nextIndex < items.count {
            let d = items[nextIndex]
            if d.startSec > until { break }
            nextIndex += 1
            if d.startSec < now - 0.4 { continue }   // 已经过去太久，丢弃
            emit(d, now: now)
        }

        // 清理已飞完的
        let expire = now - settings.duration - 1.0
        for (id, l) in live where (l.value(forKeyPath: "startSec") as? Double ?? 0) < expire {
            l.removeFromSuperlayer()
            live.removeValue(forKey: id)
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

        // 关键：预排程。起始时间对齐到弹幕真实时间点。
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

    private func rebuildAll() {
        clearLive()
        nextIndex = indexFor(time: currentTime)
        schedule()
    }

    private func laneCount() -> Int {
        let usable = Double(bounds.height) * settings.areaRatio - settings.topInset
        let laneH = settings.fontSize * 1.85
        return max(1, min(14, Int(usable / laneH)))
    }

    // MARK: 文字贴图

    /// 把文字（含描边）画成一张图，缓存复用。
    /// 用图片而不是 CATextLayer：CATextLayer 不支持描边，且每帧都要排版。
    private func image(for text: String) -> CGImage? {
        let key = "\(Int(settings.fontSize))|\(settings.stroke ? 1 : 0)|\(text)" as NSString
        if let c = imageCache.object(forKey: key) { return c }

        let font = UIFont.systemFont(ofSize: CGFloat(settings.fontSize),
                                    weight: .medium)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        if settings.stroke {
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -3.2   // 负值 = 描边 + 填充
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
