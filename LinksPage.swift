import SwiftUI

private let linkFont = Font.system(size: 12)

private extension View {
    func linkField() -> some View {
        textFieldStyle(.plain)
            .font(linkFont)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .surface(.control, radius: 9)
    }
}

// What a page needs to reach another page: a row with a chevron.
private struct LinkNavRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @Environment(\.glass) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(detail).font(.system(size: 12)).foregroundStyle(look.sub).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(look.sub)
            }
        }
        .buttonStyle(PressStyle())
    }
}

private struct TargetMenu: View {
    @ObservedObject var links: Links
    let current: LinkTarget
    var allowsPrompt = true
    let choose: (LinkTarget) -> Void

    var body: some View {
        Menu {
            if allowsPrompt {
                Button("Ask Every Time") { choose(.prompt) }
                Divider()
            }
            ForEach(links.allTargets) { target in
                Button(links.title(of: target)) { choose(target) }
            }
            Divider()
            Menu("Other App") {
                ForEach(links.allApps(), id: \.id) { app in
                    Button(app.name) { choose(LinkTarget(app: app.id)) }
                }
            }
        } label: {
            Text(links.title(of: current) + " ›").lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: Main page

struct LinksCard: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    private var quick: [LinkTarget] { Array(links.shownTargets.prefix(4)) }

    var body: some View {
        Button { model.go(.links) } label: {
            HStack(spacing: 12) {
                TileIcon(symbol: "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Links").font(.system(size: 13, weight: .bold))
                    HStack(spacing: 6) {
                        Dot(tone: links.isDefault ? .good : .off)
                        Text(links.isDefault ? "Opening in \(links.title(of: links.primary))" : "Gremlin isn't the default browser").lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(look.sub)
                }
                Spacer(minLength: 0)
                if links.isDefault {
                    HStack(spacing: 2) {
                        ForEach(quick) { target in
                            Button { links.config.primary = target } label: {
                                if let icon = links.icon(of: target) {
                                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                        .padding(2)
                                        .background {
                                            if target == links.primary { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(look.fill(0.2)) }
                                        }
                                }
                            }
                            .buttonStyle(PressStyle())
                            .help("Open links in \(links.title(of: target))")
                            .accessibilityLabel("Open links in \(links.title(of: target))")
                        }
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(look.sub)
            }
            .padding(12)
            .surface(.card)
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: Links

struct LinksPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Links", back: { model.go(.main) }) { EmptyView() }
            defaultCard
            PageGroup(title: "Where links open") {
                PageRow(title: "Default", detail: "Unless a rule says otherwise") {
                    TargetMenu(links: links, current: links.primary) { links.config.primary = $0 }
                }
                PageRow(title: "While holding \(links.config.modifier.title)", detail: "For the odd link") {
                    TargetMenu(links: links, current: links.config.alternative) { links.config.alternative = $0 }
                }
                PageRow(title: "Key to hold", detail: "Some keyboards don't send Fn") {
                    Menu {
                        ForEach(LinkConfig.Modifier.allCases, id: \.self) { modifier in
                            Button(modifier.title) { links.config.modifier = modifier }
                        }
                    } label: {
                        Text(links.config.modifier.title + " ›")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            VStack(spacing: 12) {
                LinkNavRow(symbol: "arrow.triangle.branch", title: "Rules", detail: links.config.rules.isEmpty ? "None" : "\(links.config.rules.count)") { model.go(.linkRules) }
                LinkNavRow(symbol: "square.grid.2x2", title: "Apps", detail: "Zoom, Meet and more") { model.go(.linkApps) }
                LinkNavRow(symbol: "safari", title: "Browsers", detail: "\(links.shownTargets.count) in the picker") { model.go(.linkBrowsers) }
                LinkNavRow(symbol: "clock", title: "History", detail: links.recent.isEmpty ? "Empty" : "\(links.recent.count)") { model.go(.linkHistory) }
            }
            .padding(12)
            .surface(.card)
            PageGroup(title: "Clean up every link") {
                toggle("Remove tracking", "utm_source, fbclid and 200 others", \.removeTracking)
                toggle("Unwrap redirect links", "Google, Outlook SafeLinks, Slack and more", \.unwrapRedirects)
                toggle("Expand short links", "Asks the shortener where bit.ly and t.co go", \.expandShort)
                if links.config.expandShort {
                    TextField("More short link sites, e.g. go.example.com", text: shortHosts).linkField()
                }
            }
            PageGroup(title: "Where would this link go?") {
                TextField("Paste a link and press Return", text: $links.testText)
                    .linkField()
                    .onSubmit { links.test(links.testText) }
                if let result = links.testResult {
                    Text(result).font(.system(size: 11)).foregroundStyle(look.sub).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Open Copied Link  ⌃⌥⌘L") {
                links.openCopiedLink()
                model.perform(.closePanel)
            }
            .buttonStyle(PillStyle(wide: true))
        }
    }

    private var shortHosts: Binding<String> {
        Binding {
            links.config.shortHosts.joined(separator: ", ")
        } set: {
            links.config.shortHosts = $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
    }

    @ViewBuilder private var defaultCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Dot(tone: links.isDefault ? .good : .off)
                    Text(links.isDefault ? "Gremlin is handling your links" : "Gremlin isn't the default browser")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(links.isDefault ? "Each one goes where you've set it to." : "Nothing here applies until it is. macOS asks you first.")
                    .font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if links.isDefault {
                Button("Stop") {
                    links.stopBeingDefault()
                    model.perform(.closePanel)
                }
                .buttonStyle(PillStyle())
                .help("Makes \(links.title(of: links.primary)) the default browser again")
            } else {
                Button("Make Default") {
                    links.makeDefault()
                    model.perform(.closePanel)
                }
                .buttonStyle(PillStyle(kind: .prominent))
            }
        }
        .padding(12)
        .surface(.card)
    }

    private func toggle(_ title: String, _ detail: String, _ key: WritableKeyPath<LinkConfig, Bool>) -> some View {
        PageRow(title: title, detail: detail) {
            GlassSwitch(label: title, isOn: links.config[keyPath: key]) { links.config[keyPath: key].toggle() }
        }
    }
}

// MARK: Rules

struct LinkRulesPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Rules", back: { model.go(.links) }) {
                Button {
                    let rule = LinkRule(matchers: [LinkMatcher()])
                    links.config.rules.insert(rule, at: 0)
                    links.editing = rule.id
                    model.go(.linkRule)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(RoundStyle())
                .accessibilityLabel("Add Rule")
            }
            if links.config.rules.isEmpty {
                Text("A rule sends links from a site or an app to a browser, a profile or another app. The first one that fits wins.\n\nThe quickest way to make one: ⌘-click a browser in the picker.")
                    .font(.system(size: 12)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(.card)
            }
            ForEach(links.config.rules) { rule in
                HStack(spacing: 10) {
                    GlassSwitch(label: rule.name, isOn: rule.isOn) { update(rule) { $0.isOn.toggle() } }
                    Button {
                        links.editing = rule.id
                        model.go(.linkRule)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.name.isEmpty ? "Untitled" : rule.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(summary(rule)).font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(look.sub)
                        }
                    }
                    .buttonStyle(PressStyle())
                    let isFirst = rule.id == links.config.rules.first?.id
                    // Hidden rather than left out, so the chevrons stay in a line.
                    Button { links.moveUp(rule, in: \.rules) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(RoundStyle(size: 24))
                        .help("Check this rule sooner")
                        .accessibilityLabel("Move \(rule.name) up")
                        .opacity(isFirst ? 0 : 1)
                        .disabled(isFirst)
                }
                .padding(12)
                .surface(.card)
            }
            PageGroup(title: "Before any rule, run this on every link") {
                ScriptEditor(text: $links.config.script)
                Text("JavaScript with `url` and `sourceApp`. Return a new link, or nothing to leave it. If it fails or takes over a second, the link carries on as it was.")
                    .font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Copy Rules") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(links.rulesText(), forType: .string)
                }
                Button("Paste Rules") {
                    links.addRules(fromText: NSPasteboard.general.string(forType: .string) ?? "")
                }
            }
            .buttonStyle(PillStyle(wide: true))
        }
    }

    private func update(_ rule: LinkRule, _ change: (inout LinkRule) -> Void) {
        guard let index = links.config.rules.firstIndex(of: rule) else { return }
        change(&links.config.rules[index])
    }

    private func summary(_ rule: LinkRule) -> String {
        let what = rule.matchers.map(\.value).filter { !$0.isEmpty } + rule.sources.map { id in links.appURL(id).map(Browsers.name) ?? id }
        return (what.isEmpty ? "Matches nothing yet" : what.joined(separator: ", ")) + " → " + links.title(of: rule.target)
    }
}

private struct ScriptEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .writingToolsBehavior(.disabled)
            .padding(6)
            .frame(height: 70)
            .surface(.control, radius: 10)
    }
}

struct LinkRulePage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look
    private let sample = State(initialValue: "")

    private var index: Int? { links.config.rules.firstIndex { $0.id == links.editing } }

    var body: some View {
        if let index {
            let rule = $links.config.rules[index]
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Rule", back: { model.go(.linkRules) }) { EmptyView() }
                PageGroup(title: "Name and destination") {
                    TextField("Name", text: rule.name).linkField()
                    PageRow(title: "Open in", detail: nil) {
                        TargetMenu(links: links, current: rule.wrappedValue.target) { rule.wrappedValue.target = $0 }
                    }
                }
                PageGroup(title: "Links that match any of these") {
                    ForEach(rule.matchers) { $matcher in
                        HStack(spacing: 6) {
                            Menu {
                                ForEach(LinkMatcher.Kind.allCases, id: \.self) { kind in
                                    Button(kind.title) { matcher.kind = kind }
                                }
                            } label: {
                                Text(matcher.kind.title + " ›").font(linkFont).foregroundStyle(look.sub)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .fixedSize()
                            TextField(placeholder(matcher.kind), text: $matcher.value).linkField()
                                .overlay(alignment: .trailing) {
                                    if !matcher.isValid {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).padding(.trailing, 8)
                                            .help("This regex doesn't compile, so the rule skips it")
                                    }
                                }
                            Button { rule.wrappedValue.matchers.removeAll { $0.id == matcher.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(RoundStyle(size: 24))
                                .accessibilityLabel("Remove")
                        }
                    }
                    Button("Add a Link Condition") { rule.wrappedValue.matchers.append(LinkMatcher()) }
                        .buttonStyle(PillStyle(wide: true))
                }
                PageGroup(title: "Clicked in any of these apps") {
                    ForEach(rule.wrappedValue.sources, id: \.self) { id in
                        HStack(spacing: 8) {
                            if let url = links.appURL(id) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                            }
                            Text(links.appURL(id).map(Browsers.name) ?? id).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { rule.wrappedValue.sources.removeAll { $0 == id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(RoundStyle(size: 24))
                                .accessibilityLabel("Remove")
                        }
                    }
                    Menu {
                        Section("Open Now") {
                            ForEach(links.runningApps(), id: \.id) { app in
                                Button(app.name) { add(app.id, to: rule) }
                            }
                        }
                        Menu("All Apps") {
                            ForEach(links.allApps(), id: \.id) { app in
                                Button(app.name) { add(app.id, to: rule) }
                            }
                        }
                    } label: {
                        Text(rule.wrappedValue.sources.isEmpty ? "Any app ›" : "Add an App ›").font(linkFont).foregroundStyle(look.sub)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    if !rule.wrappedValue.matchers.isEmpty, !rule.wrappedValue.sources.isEmpty {
                        Text("Both must fit: the link and the app.").font(.system(size: 11)).foregroundStyle(look.sub)
                    }
                }
                PageGroup(title: "Change the link (optional)") {
                    ScriptEditor(text: rule.script)
                    Text("Runs once this rule has matched, so it can't change which rule matches.")
                        .font(.system(size: 11)).foregroundStyle(look.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PageGroup(title: "Try a link") {
                    TextField("https://…", text: sample.projectedValue).linkField()
                    if let url = LinkCleaner.httpURL(sample.wrappedValue) {
                        let matched = rule.wrappedValue.matchers.isEmpty ? nil : rule.wrappedValue.matchers.contains { $0.matches(url) }
                        HStack(spacing: 6) {
                            Dot(tone: matched == false ? .off : .good)
                            Text(matched == false ? "Doesn't match" : matched == true ? "Matches" : "Any link matches")
                                .font(.system(size: 11)).foregroundStyle(look.sub)
                        }
                    }
                }
                Button("Delete Rule") {
                    let id = links.editing
                    model.go(.linkRules)
                    links.editing = nil
                    links.config.rules.removeAll { $0.id == id }
                }
                .buttonStyle(PillStyle(kind: .danger, wide: true))
            }
        }
    }

    private func add(_ id: String, to rule: Binding<LinkRule>) {
        if !rule.wrappedValue.sources.contains(id) { rule.wrappedValue.sources.append(id) }
    }

    private func placeholder(_ kind: LinkMatcher.Kind) -> String {
        switch kind {
        case .domain: "github.com"
        case .prefix: "github.com/bunniesinc"
        case .regex: "^https://.*\\.example\\.com/"
        }
    }
}

// MARK: Browsers

struct LinkBrowsersPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    private var hidden: [LinkTarget] {
        links.allTargets.filter { !links.config.shown.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Browsers", back: { model.go(.links) }) { EmptyView() }
            PageGroup(title: "In the picker, in this order") {
                let shown = links.shownTargets
                ForEach(shown) { target in
                    row(target, isOn: true, canMoveUp: target != shown.first)
                }
                if shown.isEmpty {
                    Text("With nothing here, links skip the picker and go to the default.").font(.system(size: 11)).foregroundStyle(look.sub)
                }
            }
            if !hidden.isEmpty {
                PageGroup(title: "Not shown") {
                    ForEach(hidden) { target in
                        row(target, isOn: false, canMoveUp: false)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Find Profiles") { links.findProfiles() }
                    .buttonStyle(PillStyle(wide: true))
                Text(profileNote).font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileNote: String {
        if links.profilesDenied.isEmpty {
            return "Chrome, Edge, Brave, Vivaldi and Firefox keep their profiles in their own folders. macOS may ask whether Gremlin can read them."
        }
        let names = links.browsers.filter { links.profilesDenied.contains($0.id) }.map(\.name).joined(separator: ", ")
        return "macOS didn't let Gremlin read \(names)'s folder. Allow it in System Settings › Privacy & Security › App Management or Full Disk Access, then try again."
    }

    private func row(_ target: LinkTarget, isOn: Bool, canMoveUp: Bool) -> some View {
        HStack(spacing: 8) {
            if let icon = links.icon(of: target) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            Text(links.title(of: target)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if isOn {
                TextField(links.pickerKeys(for: links.shownTargets)[target.id]?.uppercased() ?? "", text: key(target))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .surface(.control, radius: 7)
                    .help("The key that picks it")
                if canMoveUp {
                    Button { links.moveUp(target, in: \.shown) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(RoundStyle(size: 24))
                        .accessibilityLabel("Move \(links.title(of: target)) up")
                }
            }
            GlassSwitch(label: links.title(of: target), isOn: isOn) { links.toggleShown(target) }
        }
    }

    private func key(_ target: LinkTarget) -> Binding<String> {
        Binding {
            links.config.keys[target.id]?.uppercased() ?? ""
        } set: { text in
            links.config.keys[target.id] = text.last(where: \.isLetter).map { String($0).lowercased() }
        }
    }
}

// MARK: Apps

struct LinkAppsPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Apps", back: { model.go(.links) }) { EmptyView() }
            PageGroup(title: "These links skip the browser") {
                ForEach(links.installedLinkApps) { app in
                    let name = app.apps.compactMap { links.appURL($0) }.first.map(Browsers.name) ?? app.title
                    PageRow(title: app.title, detail: "Opens in \(name)") {
                        GlassSwitch(label: app.title, isOn: !links.config.appsOff.contains(app.id)) {
                            if links.config.appsOff.contains(app.id) {
                                links.config.appsOff.remove(app.id)
                            } else {
                                links.config.appsOff.insert(app.id)
                            }
                        }
                    }
                }
                if links.installedLinkApps.isEmpty {
                    Text("None of the apps Gremlin knows about are installed.").font(.system(size: 11)).foregroundStyle(look.sub)
                }
            }
            Text("Works for \(LinkApp.all.map(\.title).joined(separator: ", ")) when installed. Rules come first, and any other app can be the target of a rule.")
                .font(.system(size: 11)).foregroundStyle(look.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: History

struct LinkHistoryPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "History", back: { model.go(.links) }) {
                if !links.recent.isEmpty {
                    Button("Clear") { links.clearHistory() }.buttonStyle(PillStyle())
                }
            }
            PageGroup(title: "Remembering") {
                PageRow(title: "Keep it after quitting", detail: links.config.keepHistory ? "Up to 500 links, on this Mac only" : "The last 50, until Gremlin quits") {
                    GlassSwitch(label: "Keep it after quitting", isOn: links.config.keepHistory) { links.setKeepHistory(!links.config.keepHistory) }
                }
            }
            if links.recent.isEmpty {
                Text("Links show up here with the app they came from and why they went where they went.")
                    .font(.system(size: 12)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(links.recent.prefix(12)) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(string: event.opened)?.host ?? event.opened).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(event.target) · \(event.why)").font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(1)
                    Text([event.source, event.date.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(1)
                }
                .help(event.received == event.opened ? event.opened : "\(event.received)\n→ \(event.opened)")
            }
        }
    }
}
