import SwiftUI

// Pieces shared by the Restart, iPad, Universal Control and Settings screens.
enum DevicesParts {
    /// A colored icon, a title with a line under it, and a control on the right.
    struct Row<Trailing: View>: View {
        let symbol: String
        let tint: Color
        let title: String
        var detail: String?
        @ViewBuilder var trailing: Trailing

        var body: some View {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }

    /// A shortcut like "⌃⌥⌘S" as a cap per key.
    struct Keys: View {
        let keys: String
        var small = true

        var body: some View {
            HStack(spacing: small ? 3 : 5) {
                ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: String($0.element), small: small) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys)
        }
    }

    /// A numbered step in a short explainer.
    struct Step: View {
        let number: Int
        let text: String
        var tint: Color

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tint.gradient))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A spinning arc in a color, which keeps its color when the window isn't key.
    struct Spinner: View {
        var tint: Color
        var size: CGFloat = 14
        var line: CGFloat = 2

        var body: some View {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Circle().stroke(tint.opacity(0.25), lineWidth: line)
                    .overlay(Circle().trim(from: 0, to: 0.28).stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360)))
                    .frame(width: size - line, height: size - line)
                    .frame(width: size, height: size)
            }
        }
    }

    /// The well's own heading, for wells that need a control beside it.
    struct Heading<Trailing: View>: View {
        let title: String
        @ViewBuilder var trailing: Trailing

        var body: some View {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
        }
    }

    /// A big faint glyph in a corner, like the ones on vivid tiles.
    struct Watermark: View {
        let symbol: String
        var tint: Color
        var size: CGFloat = 96
        var opacity: Double = 0.07

        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint.opacity(opacity))
                .rotationEffect(.degrees(-12))
                .offset(x: size * 0.18, y: size * 0.2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Press feedback for big tiles.
    struct TileStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(Motion.snappy, value: configuration.isPressed)
        }
    }
}

extension DevicesParts.Row where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}
