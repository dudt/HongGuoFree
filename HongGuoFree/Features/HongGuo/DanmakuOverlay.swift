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
            let laneHeight = min(30, h / CGFloat(max(engine.laneCount, 1) + 2))

            ZStack(alignment: .topLeading) {
                ForEach(engine.active) { d in
                    Text(d.text)
                        .font(.system(size: engine.fontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(
                            x: xOffset(for: d, width: w),
                            y: 10 + CGFloat(d.lane) * laneHeight
                        )
                }
            }
            .opacity(engine.opacity)
            .allowsHitTesting(false)
        }
    }

    /// 从右侧 w 移动到左侧 -w，全程 duration 秒
    private func xOffset(for d: DanmakuEngine.ActiveDanmaku, width: CGFloat) -> CGFloat {
        let elapsed = currentTime - d.startSec
        let progress = max(0, min(1, elapsed / max(d.duration, 0.1)))
        let start = width
        let end = -width
        return start + (end - start) * CGFloat(progress)
    }
}
