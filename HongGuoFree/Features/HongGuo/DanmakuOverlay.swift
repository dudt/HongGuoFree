// 弹幕渲染层
//
// 滚动方式：每条弹幕从右边界进入，向左移动直到完全离开。
// 位置由「当前播放时间 - 弹幕起始时间」算出，所以暂停/拖动/倍速都能自然跟随。
import SwiftUI

struct DanmakuOverlay: View {
    @ObservedObject var engine: DanmakuEngine
    /// 当前播放时间（秒）
    let currentTime: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let laneHeight = min(28, h / CGFloat(max(engine.laneCount, 1) + 1))

            ZStack(alignment: .topLeading) {
                ForEach(engine.active) { d in
                    Text(d.text)
                        .font(.system(size: engine.fontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(
                            x: xOffset(for: d, width: w),
                            y: 8 + CGFloat(d.lane) * laneHeight
                        )
                }
            }
            .opacity(engine.opacity)
            .allowsHitTesting(false)
        }
    }

    /// 从右侧 w 移动到左侧 -textWidth
    private func xOffset(for d: DanmakuEngine.ActiveDanmaku, width: CGFloat) -> CGFloat {
        let elapsed = currentTime - d.startSec
        let progress = max(0, min(1, elapsed / d.duration))
        // 起点在屏幕右侧，终点在屏幕左侧外
        let start = width
        let end = -width * 0.6
        return start + (end - start) * CGFloat(progress)
    }
}
