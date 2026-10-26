// 弹幕渲染层
//
// 用 TimelineView(.animation) 让 SwiftUI 自己按帧插值，
// 不在每次播放时间回调里重建数组 —— 这是旧版卡顿的根因。
// 时间基准用外部传入的 playerTime（播放器当前秒数），
// 所以暂停 / 拖动 / 倍速都自动跟随。
import SwiftUI

struct DanmakuOverlay: View {
    @ObservedObject var engine: DanmakuEngine
    /// 播放器当前时间（秒）
    let playerTime: Double
    /// 是否暂停（暂停时冻结画面）
    let isPaused: Bool

    /// 上一帧的时间，用于平滑插值
    @State private var displayTime: Double = 0
    @State private var lastRealTime: Double = 0

    var body: some View {
        GeometryReader { geo in
            let lanes = engine.laneCount(for: geo.size.height)
            let laneHeight = engine.settings.fontSize * 1.9
            let top = engine.settings.topInset

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { ctx in
                Canvas { context, size in
                    draw(context: context, size: size,
                         lanes: lanes, laneHeight: laneHeight, top: top)
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(engine.settings.enabled ? 1 : 0)
    }

    private func draw(context: GraphicsContext, size: CGSize,
                      lanes: Int, laneHeight: Double, top: Double) {
        guard engine.settings.enabled, !engine.scheduled.isEmpty else { return }

        let now = playerTime
        let dur = max(engine.settings.duration, 0.5)
        let w = size.width
        let font = Font.system(size: engine.settings.fontSize, weight: .medium)

        // 只取当前可见区间，二分定位可以更快，这里用简单过滤已足够
        let lower = now - dur - 0.5
        let upper = now + 0.2

        for d in engine.scheduled {
            if d.startSec > upper { break }
            if d.startSec < lower { continue }
            if d.lane >= lanes { continue }

            let progress = (now - d.startSec) / dur
            if progress < 0 || progress > 1 { continue }

            // 从右侧进入，完全移出左侧
            let x = w - (w + w * 0.9) * progress
            let y = top + Double(d.lane) * laneHeight

            var text = Text(d.text).font(font)
            if engine.settings.stroke {
                text = text
                    .foregroundColor(.white)
            } else {
                text = text.foregroundColor(.white)
            }

            let resolved = context.resolve(text)
            var ctx = context
            ctx.opacity = engine.settings.opacity
            ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .leading)

            // 描边：同一段文字偏移画四角，做出黑边效果
            if engine.settings.stroke {
                var shadowCtx = context
                shadowCtx.opacity = engine.settings.opacity * 0.85
                let strokeText = context.resolve(
                    Text(d.text).font(font).foregroundColor(.black)
                )
                for (dx, dy) in [(-1.2, 0.0), (1.2, 0.0), (0.0, -1.2), (0.0, 1.2)] {
                    shadowCtx.draw(strokeText,
                                   at: CGPoint(x: x + dx, y: y + dy),
                                   anchor: .leading)
                }
            }
        }
    }
}
