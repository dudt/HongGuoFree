// 设计系统：颜色、字体、圆角、动效
import SwiftUI
import Foundation

enum Palette {
    static let accent = Color(hex: 0xFF3B5C)
    static let accentSoft = Color(hex: 0xFF7A5C)
    static let gold = Color(hex: 0xFFC24B)

    static let background = Color(hex: 0x0B0B10)
    static let surface = Color(hex: 0x14141C)
    static let surfaceHigh = Color(hex: 0x1D1D28)
    static let stroke = Color.white.opacity(0.08)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    static func gradient(for seed: String) -> LinearGradient {
        let hash = seed.stableHash.magnitude
        let hue = Double(hash % 360) / 360.0
        let start = Color(hue: hue, saturation: 0.62, brightness: 0.72)
        let end = Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                        saturation: 0.78, brightness: 0.42)
        return LinearGradient(colors: [start, end],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }
}

enum Radius {
    static let card: CGFloat = 18
    static let chip: CGFloat = 12
    static let poster: CGFloat = 14
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

extension String {
    /// 稳定哈希：同一剧名每次启动颜色一致
    var stableHash: Int {
        var hash = 5381
        for scalar in unicodeScalars {
            hash = (hash &* 33) &+ Int(scalar.value)
        }
        return hash
    }
}

extension Double {
    var timeText: String {
        guard isFinite, self > 0 else { return "00:00" }
        let total = Int(rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PosterPlaceholder: View {
    let title: String
    var icon: String = "play.tv"

    var body: some View {
        ZStack {
            Palette.gradient(for: title)
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(String(title.prefix(6)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

struct TagChip: View {
    let text: String
    var highlighted: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(highlighted ? Color.white : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(highlighted ? Palette.accent.opacity(0.22) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(highlighted ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.accent))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
