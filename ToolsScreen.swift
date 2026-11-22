import SwiftUI

// The four tools, each with what it does and its shortcut, and the switch that does Fix Focus on its own.
struct ToolsScreen: View {
    var body: some View {
        ScreenCard(module: .tools) {
            HeaderNote(text: "Shortcuts work in any app", symbol: "keyboard")
        } content: {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    ToolCard(tool: ToolsCatalog.all[0])
                    ToolCard(tool: ToolsCatalog.all[1])
                }
                HStack(spacing: 14) {
                    ToolCard(tool: ToolsCatalog.all[2])
                    ToolCard(tool: ToolsCatalog.all[3])
                }
                AutoFixRow()
            }
        }
    }
}

private struct ToolCard: View {
    let tool: ToolsCatalog.Tool
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        Well(padding: 18, fill: true) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: tool.symbol, tint: Palette.sky, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(tool.hint).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ToolDemo(id: tool.id)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.page))
            Text(tool.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                ForEach(Array(tool.keys).map(String.init), id: \.self) { Keycap(text: $0) }
                Spacer(minLength: 8)
                Button("Try it") { model.perform(tool.action) }
                    .buttonStyle(CapsuleButton(tint: Palette.sky, soft: true))
                    .help("\(tool.title) now  \(tool.keys)")
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ToolDemo: View {
    let id: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            demo(labels: true)
            demo(labels: false)
        }
        .padding(.horizontal, 14)
        .accessibilityHidden(true)
    }

    private func demo(labels: Bool) -> some View {
        HStack(spacing: 12) {
            switch id {
            case "grab":
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([0.9, 0.65, 0.8], id: \.self) { width in
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 90 * width, height: 5)
                    }
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.sky, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                arrow
                chip(labels ? "“Ship it on Monday”" : "“Ship it”", mono: false)
            case "color":
                HStack(spacing: -6) {
                    ForEach([Palette.indigo, Palette.holoMint, Palette.coral, Palette.amber], id: \.self) { color in
                        Circle().fill(color).frame(width: 24, height: 24).overlay(Circle().strokeBorder(Palette.page, lineWidth: 2))
                    }
                }
                Circle().fill(Palette.accent).frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: Palette.accent.opacity(0.5), radius: 5)
                arrow
                chip("#9B6BFF", mono: true)
            case "paste":
                Text("Bold, links, fonts")
                    .font(.system(size: 13, weight: .heavy, design: .serif)).italic().underline()
                    .foregroundStyle(LinearGradient(colors: [Palette.pink, Palette.iris], startPoint: .leading, endPoint: .trailing))
                    .fixedSize()
                arrow
                chip("Bold, links, fonts", mono: false)
            default:
                Image(systemName: "macwindow").font(.system(size: 22)).foregroundStyle(.tertiary)
                if labels { Text("Typing goes nowhere").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
                arrow
                Image(systemName: "macwindow.badge.plus").font(.system(size: 22)).foregroundStyle(Palette.sky)
                if labels { Text("Back in the window").font(.system(size: 12, weight: .semibold)).fixedSize() }
            }
        }
        .fixedSize()
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.sky)
    }

    private func chip(_ text: String, mono: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.well))
    }
}

private struct AutoFixRow: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let on = model.switches[AppSwitch.autoFixFocus] ?? false
        Well(padding: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "scope", tint: Palette.mint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Auto-Fix Lost Focus").font(.system(size: 13.5, weight: .semibold))
                        if !model.accessibility {
                            Text("Needs Accessibility")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Ink.amber)
                                .padding(.horizontal, 7)
                                .frame(height: 19)
                                .background(Capsule().fill(Palette.warn.opacity(0.16)))
                        }
                    }
                    Text("Does Fix Focus for you when the front app's windows have had no focus for 3 seconds.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !model.accessibility {
                    Button("Allow in Settings") { model.perform(.open(ToolsCatalog.accessibilitySettings)) }
                        .buttonStyle(CapsuleButton(tint: Palette.warn, soft: true))
                        .help("Opens Privacy & Security › Accessibility")
                }
                ToggleSwitch(isOn: on, tint: Palette.mint, label: "Auto-Fix Lost Focus") {
                    model.perform(.setSwitch(AppSwitch.autoFixFocus, !on))
                }
            }
        }
    }
}
