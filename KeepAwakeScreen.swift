import AppKit
import SwiftUI

// The dial and stops, when it ends, what else is holding the Mac awake, and what happens after a restart.
struct KeepAwakeScreen: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let awake = model.awakeStop > 0
        ScreenCard(module: .keepAwake) {
            HeaderNote(text: awake ? model.awakeText : "Sleeping as usual", symbol: awake ? "clock.fill" : "moon.zzz.fill")
                .contentTransition(.opacity)
        } content: {
            VStack(spacing: 14) {
                AwakeMain()
                HStack(alignment: .top, spacing: 14) {
                    AwakeOthers()
                    Well("After a Gremlin restart", fill: true) {
                        AwakeFact(symbol: "arrow.triangle.2.circlepath", tint: Palette.amber, title: "It picks up again",
                                  detail: "Keep Awake carries on until its time is up.")
                    }
                    Well("When time runs out", fill: true) {
                        AwakeFact(symbol: "moon.zzz.fill", tint: Palette.iris, title: "Sleeps the usual way",
                                  detail: "Your Energy settings take over again.")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AwakeMain: View {
    @EnvironmentObject private var model: MenuModel
    @Namespace private var stops

    var body: some View {
        let awake = model.awakeStop > 0
        Well(padding: 26, fill: true) {
            HStack(spacing: 40) {
                KeepAwakeDial(stop: model.awakeStop, value: KeepAwakeInfo.value(model.awakeStop), caption: KeepAwakeInfo.caption(model),
                              labels: true) { pick($0) }
                    .frame(minWidth: 230, idealWidth: 230, maxWidth: 330, minHeight: 230, idealHeight: 230, maxHeight: 330)
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(awake ? "Staying awake" : "Sleeping as usual")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .contentTransition(.opacity)
                        Text(awake ? "The Mac and the display stay awake" : "The Mac sleeps when it normally would")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    segments
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.bouncy, value: model.awakeStop)
    }

    private var segments: some View {
        HStack(spacing: 0) {
            ForEach(MenuModel.awakeStops.indices, id: \.self) { index in
                let on = index == model.awakeStop
                Button { pick(index) } label: {
                    Text(MenuModel.awakeStops[index])
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if on {
                                Capsule().fill(LinearGradient(colors: Module.keepAwake.fill, startPoint: .top, endPoint: .bottom))
                                    .shadow(color: Palette.amber.opacity(0.35), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "stop", in: stops)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(index == 0 ? "Off" : index == KeepAwakeInfo.last ? "Until you stop it" : MenuModel.awakeStops[index])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.well2))
    }

    private var hint: String {
        switch model.awakeStop {
        case 0: "Drag the knob or click a stop to keep the Mac awake."
        case KeepAwakeInfo.last: "Drag the knob or click a stop. It stays on until you pick Off."
        default: "Drag the knob or click a stop. It slides down as time runs out."
        }
    }

    private func pick(_ stop: Int) {
        withAnimation(Motion.bouncy) { model.perform(.keepAwake(stop)) }
    }
}

/// Other apps holding the Mac awake, like a video call or caffeinate.
private struct AwakeOthers: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        Well("Also keeping the Mac awake", fill: true) {
            if model.awakeOthers.isEmpty {
                AwakeFact(symbol: "checkmark", tint: Palette.mint, title: "Nothing else", detail: "No other app is holding it awake.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.awakeOthers.prefix(3), id: \.self) { name in
                        HStack(spacing: 12) {
                            AppIcon(name: name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                Text("Asked macOS to stay awake").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if model.awakeOthers.count > 3 {
                        Text("and \(model.awakeOthers.count - 3) more").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AppIcon: View {
    let name: String

    var body: some View {
        if let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
        } else {
            IconTile(symbol: "app.dashed", tint: Palette.slate, size: 30)
        }
    }
}

private struct AwakeFact: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
