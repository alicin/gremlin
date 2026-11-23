import AppKit
import SwiftUI

// Home: a greeting that says what's going on, anything that needs a look, and a board of live widgets, one per
// module. The board fills the window in three bands; below the size they need, it scrolls.
struct HomeScreen: View {
    @EnvironmentObject private var model: MenuModel

    private static let gap: CGFloat = 12
    private static let top: CGFloat = 22
    private static let greeting: CGFloat = 68
    private static let section: CGFloat = 14
    private static let banner: CGFloat = 60
    private static let bottom: CGFloat = 10
    private static let trailing: CGFloat = 8
    // What each band needs; a taller window shares out up to a third more.
    private static let bands: [CGFloat] = [296, 150, 156]

    private var banners: [MenuModel.Banner] {
        // The transcript or compression under way already shows in Record and Meetings.
        model.banners.filter { $0.kind != .working }
    }

    var body: some View {
        GeometryReader { geo in
            let column = floor((geo.size.width - Self.trailing - Self.gap * 3) / 4)
            let wide = column * 2 + Self.gap
            let shown = banners
            let fixed = Self.top + Self.greeting + Self.section + CGFloat(shown.count) * (Self.banner + Self.gap) + Self.gap * 2 + Self.bottom
            let base = Self.bands.reduce(0, +)
            let extra = min(max(0, geo.size.height - fixed - base), base / 3)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    HomeGreeting()
                        .frame(height: Self.greeting)
                        .padding(.bottom, Self.section)
                    ForEach(shown) { banner in
                        HomeBanner(banner: banner, perform: model.perform)
                            .frame(height: Self.banner)
                            .padding(.bottom, Self.gap)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    VStack(spacing: Self.gap) {
                        HStack(spacing: Self.gap) {
                            HomeRecordWidget().frame(width: wide)
                            HomeAwakeWidget().frame(width: column)
                            VStack(spacing: Self.gap) {
                                HomeDisplaysWidget()
                                HomeDrivesWidget()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(height: Self.bands[0] + extra * 0.5)
                        HStack(spacing: Self.gap) {
                            HomeToolsWidget().frame(width: wide)
                            Group {
                                if let ipad = model.ipad { HomeIPadWidget(ipad: ipad) } else { HomeRestartWidget() }
                            }
                            .frame(width: column)
                            HomeUniversalControlWidget().frame(maxWidth: .infinity)
                        }
                        .frame(height: Self.bands[1] + extra * 0.25)
                        HStack(spacing: Self.gap) {
                            HomeMeetingsWidget().frame(width: wide)
                            HomeVPNWidget().frame(width: column)
                            HomeLinksWidget().frame(maxWidth: .infinity)
                        }
                        .frame(height: Self.bands[2] + extra * 0.25)
                    }
                }
                .padding(.top, Self.top)
                .padding(.trailing, Self.trailing)
                .padding(.bottom, Self.bottom)
                .frame(width: geo.size.width, alignment: .topLeading)
                .animation(Motion.snappy, value: shown.map(\.id))
            }
            // Widget shadows reach past the edges; the window clips them anyway.
            .scrollClipDisabled()
            .scrollIndicators(geo.size.height < fixed + base ? .automatic : .never)
        }
    }
}

private struct HomeGreeting: View {
    @EnvironmentObject private var model: MenuModel
    @StateObject private var spun = Box(false)

    private static let name: String = {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.prefix(1).uppercased() + first.dropFirst()
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.everyMinute) { context in
                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(Self.name.isEmpty ? "Hey there" : "Hey, \(Self.name)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .contentTransition(.opacity)
                    .animation(Motion.snappy, value: summary)
            }
            Spacer(minLength: 12)
            HoloPaw(size: 34, sticker: true)
                .rotationEffect(.degrees(spun.value ? 346 : -14))
                .scaleEffect(spun.value ? 1.12 : 1)
                .onTapGesture { withAnimation(Motion.bouncy) { spun.value.toggle() } }
                .help("Hi from Gremlin")
                .padding(.trailing, 10)
                .accessibilityHidden(true)
        }
    }

    private var summary: String {
        var parts: [String] = []
        let problems = model.banners.filter { $0.kind == .problem }.count
        if problems > 0 { parts.append(problems == 1 ? "one thing needs a look" : "\(problems) things need a look") }
        if model.recording != nil {
            parts.append("a recording is running")
        } else if model.starting {
            parts.append("a recording is starting")
        }
        if let progress = model.notesProgress { parts.append(Self.clause(progress.title)) }
        if model.awakeStop > 0 { parts.append("the Mac is staying awake \(KeepAwakeInfo.caption(model))") }
        guard !parts.isEmpty else { return "Everything's running smoothly." }
        let sentence = ListFormatter.localizedString(byJoining: parts)
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    /// "Compressing Square sync" becomes "Square sync is being compressed".
    private static func clause(_ title: String) -> String {
        let words = title.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2 else { return "Gremlin is \(KeepAwakeInfo.lowered(title))" }
        switch words[0] {
        case "Transcribing": return "\(words[1]) is being transcribed"
        case "Summarizing": return "\(words[1]) is being summarized"
        case "Compressing": return "\(words[1]) is being compressed"
        case "Downloading": return "\(words[1]) is downloading"
        default: return "Gremlin is \(KeepAwakeInfo.lowered(title))"
        }
    }
}

/// A problem or a finished job.
private struct HomeBanner: View {
    let banner: MenuModel.Banner
    let perform: (MenuModel.Action) -> Void

    private var tint: Color { banner.kind == .problem ? Palette.warn : Palette.good }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.kind == .done ? "checkmark" : banner.symbol)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(tint.gradient))
                .shadow(color: tint.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(banner.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let title = banner.button, let action = banner.action {
                Button(title) { perform(action) }
                    .buttonStyle(CapsuleButton(tint: tint, neutral: banner.kind == .problem && banner.dismiss == nil))
            }
            if let dismiss = banner.dismiss {
                Button { perform(dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.well2))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperSurface(tint: tint, radius: 18))
    }
}
