import Foundation
import JavaScriptCore

// Where a link goes: a browser or other app, with a profile or a private window where the browser has them, or the picker.
struct LinkTarget: Codable, Hashable, Identifiable {
    static let promptID = "prompt"
    static let prompt = LinkTarget(app: promptID)

    var app: String
    var profile: String?
    var profileName: String?
    var isPrivate = false

    var isPrompt: Bool { app == Self.promptID }
    var id: String { [app, profile ?? "", isPrivate ? "private" : ""].joined(separator: "|") }

    static func == (a: LinkTarget, b: LinkTarget) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LinkMatcher: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case domain, prefix, regex

        var title: String {
            switch self {
            case .domain: "Domain"
            case .prefix: "Starts with"
            case .regex: "Regex"
            }
        }
    }

    var id = UUID()
    var kind = Kind.domain
    var value = ""

    // A domain also covers its subdomains, and may carry a path: "github.com/bunniesinc".
    func matches(_ url: URL) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch kind {
        case .domain:
            guard let host = url.host?.lowercased() else { return false }
            var wanted = value.lowercased()
            if let scheme = wanted.range(of: "://") { wanted = String(wanted[scheme.upperBound...]) }
            if wanted.hasPrefix("*.") { wanted.removeFirst(2) }
            let parts = wanted.split(separator: "/", maxSplits: 1)
            guard let domain = parts.first else { return false }
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            guard parts.count > 1 else { return true }
            return url.path.lowercased().hasPrefix("/" + parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case .prefix:
            return Self.withoutScheme(url.absoluteString).lowercased().hasPrefix(Self.withoutScheme(value).lowercased())
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
            let text = url.absoluteString
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    var isValid: Bool {
        kind != .regex || (try? NSRegularExpression(pattern: value)) != nil
    }

    private static func withoutScheme(_ text: String) -> String {
        guard let scheme = text.range(of: "://") else { return text }
        return String(text[scheme.upperBound...])
    }
}

struct LinkRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    var isOn = true
    var target = LinkTarget.prompt
    var matchers: [LinkMatcher] = []
    var sources: [String] = []
    var script = ""

    // Both kinds of condition must hold when both are given. A rule with neither never matches.
    func matches(_ url: URL, source: String?) -> Bool {
        guard isOn, !matchers.isEmpty || !sources.isEmpty else { return false }
        if !sources.isEmpty {
            guard let source, sources.contains(source) else { return false }
        }
        return matchers.isEmpty || matchers.contains { $0.matches(url) }
    }
}

// An app that a kind of link is better off in. Each is offered only when its app is installed.
struct LinkApp: Identifiable {
    let id: String
    let title: String
    // The first installed one is used.
    let apps: [String]
    let rewrite: (URL) -> URL?
}

extension LinkApp {
    static let chromium = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium", "com.vivaldi.Vivaldi"]

    static let all = [
        // Google Meet only supports everything it does in Chromium browsers.
        LinkApp(id: "meet", title: "Google Meet", apps: chromium) { host($0, "meet.google.com") ? $0 : nil },
        LinkApp(id: "zoom", title: "Zoom", apps: ["us.zoom.xos"], rewrite: zoom),
        LinkApp(id: "teams", title: "Microsoft Teams", apps: ["com.microsoft.teams2", "com.microsoft.teams"]) { url in
            guard host(url, "teams.microsoft.com"), url.path.hasPrefix("/l/") else { return nil }
            return replacing(url, scheme: "msteams", host: nil)
        },
        LinkApp(id: "figma", title: "Figma", apps: ["com.figma.Desktop"]) { url in
            guard host(url, "figma.com"), let first = url.pathComponents.dropFirst().first,
                  ["file", "design", "proto", "board", "slides", "deck"].contains(first) else { return nil }
            return appLink("figma", url)
        },
        LinkApp(id: "linear", title: "Linear", apps: ["com.linear"]) { url in
            guard host(url, "linear.app"), url.pathComponents.count > 3,
                  ["issue", "project", "team", "view", "document"].contains(url.pathComponents[2]) else { return nil }
            return appLink("linear", url)
        },
        LinkApp(id: "notion", title: "Notion", apps: ["notion.id"]) { url in
            guard host(url, "notion.so") else { return nil }
            return replacing(url, scheme: "notion", host: url.host)
        },
        LinkApp(id: "spotify", title: "Spotify", apps: ["com.spotify.client"]) { url in
            guard host(url, "open.spotify.com") else { return nil }
            let parts = url.pathComponents.dropFirst().filter { !$0.hasPrefix("intl-") }
            guard parts.count == 2 else { return nil }
            return URL(string: "spotify:\(parts[0]):\(parts[1])")
        },
        LinkApp(id: "discord", title: "Discord", apps: ["com.hnc.Discord"]) { url in
            guard host(url, "discord.com"), url.path.hasPrefix("/channels/") else { return nil }
            return URL(string: "discord://-" + url.path)
        },
    ]

    private static func host(_ url: URL, _ domain: String) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    // figma.com/design/key → figma://design/key
    private static func appLink(_ scheme: String, _ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = scheme
        parts.host = nil
        parts.port = nil
        let path = parts.percentEncodedPath
        parts.percentEncodedPath = ""
        let rest = parts.string?.dropFirst(scheme.count + 1) ?? ""
        return URL(string: "\(scheme)://\(path.dropFirst())\(rest)")
    }

    private static func replacing(_ url: URL, scheme: String, host: String?) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = scheme
        parts.host = host
        return parts.url
    }

    private static func zoom(_ url: URL) -> URL? {
        guard host(url, "zoom.us") else { return nil }
        let path = url.pathComponents.dropFirst()
        guard path.count == 2, ["j", "s", "w"].contains(path.first), let meeting = path.last, meeting.allSatisfy(\.isNumber) else { return nil }
        var parts = URLComponents()
        parts.scheme = "zoommtg"
        parts.host = "zoom.us"
        parts.path = "/join"
        parts.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: meeting)]
        if let password = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" }) {
            parts.queryItems?.append(password)
        }
        return parts.url
    }
}

// What can be done to a link without asking anything of the network.
enum LinkCleaner {
    // Query parameters that only exist to track the click.
    private static let tracking: Set<String> = [
        "_bta_c", "_bta_tid", "_ga", "_gl", "_hsenc", "_hsmi", "_ke", "_kx", "_openstat", "__hsfp", "__hssc", "__hstc",
        "action_object_map", "action_ref_map", "action_type_map", "af_ad", "af_adset", "af_channel", "af_force_deeplink",
        "af_keywords", "af_siteid", "af_sub1", "af_sub2", "af_sub3", "af_sub4", "af_sub5", "aff_platform",
        "aff_trace_key", "algo_expid", "algo_pvid", "at_campaign", "at_medium", "at_recipient_id", "at_recipient_list",
        "bbeml", "bffb", "bm_cat", "cjevent", "cmpid", "dclid", "dm_i", "ef_id", "email_source",
        "epik", "fb_action_ids", "fb_action_types", "fb_ref", "fb_source", "fbclid", "ga_campaign", "ga_content", "ga_medium",
        "ga_place", "ga_source", "ga_term", "gad_campaignid", "gad_source", "gbraid", "gclid", "gclsrc", "gs_lcp", "gs_lcrp",
        "gs_ssp", 
        "hsctatracking", "icid", "igsh", "igshid", "irclickid", "irgwc", "itm_campaign", "itm_content", "itm_medium",
        "itm_source", "itm_term", "klaviyo_id", "lctg", "li_fat_id", "mbid", "mc_cid", "mc_eid", "mkt_tok",
        "mkwid", "msclkid", "mtm_campaign", "mtm_cid", "mtm_content", "mtm_group", "mtm_keyword", "mtm_kwd", "mtm_medium",
        "mtm_placement", "mtm_source", "nb_klid", "ncid", "ndclid", "oly_anr_id", "oly_enc_id", "pk_campaign",
        "pk_cid", "pk_content", "pk_keyword", "pk_kwd", "pk_medium", "pk_source", "piwik_campaign", "piwik_keyword", "piwik_kwd",
        "pmkw", "rb_clickid", "rdt_cid", "redirect_log_mongo_id", "redirect_mongo_id", "ref_src", "ref_url", "s_cid", "s_kwcid",
        "sb_referer_host", "sc_campaign", "sc_channel", "sc_content", "sc_country", "sc_geo", "sc_medium", "sc_outcome", "sc_publisher",
        "sc_segment", "sca_esv", "scm_id", "sfmc_id", "sms_click", "sms_source", "sms_uph", "spm", "spm_id_from", "srsltid",
        "ss_email_id", "ssp_iabi", "sts_id", "tduid", "trk", "trk_contact", "trk_msg",
        "trk_module", "trk_sid", "trkcampaign", "ttclid", "twclid", "unicorn_click_id", "user_email_address", "vero_conv", "vero_id", "vgo_ee",
        "wbraid", "wickedid", "wprov", "wt.mc_id", "wt_mc", "wt_zmc", "xtor", "yclid", "ymclid", "ysclid", "zanpid", "zmc",
    ]

    // These names mean something on other sites, so they only go on the ones known to add them for tracking.
    private static let bySite: [(domains: [String], names: Set<String>)] = [
        (["x.com", "twitter.com"], ["s", "t", "cn", "ref_url"]),
        (["youtube.com", "youtu.be"], ["si", "feature", "pp", "ab_channel"]),
        (["spotify.com"], ["si", "context", "nd", "dlsi", "pt"]),
        (["tiktok.com"], ["_d", "_r", "_t", "checksum", "is_copy_url", "is_from_webapp", "language", "preview_pb", "sec_user_id", "sender_device", "share_app_id", "share_item_id", "share_link_id", "sharer_language", "source", "timestamp", "tt_from", "u_code", "user_id", "web_id"]),
        (["facebook.com", "fb.com", "fb.watch"], ["__cft__", "__tn__", "eid", "mibextid", "paipv", "rdid", "share_url", "sfnsn"]),
        (["instagram.com"], ["hl_ref", "img_index", "utm_id"]),
        (["linkedin.com"], ["lipi", "licu", "midSig", "midToken", "originalSubdomain", "rcm", "trackingId", "refId", "eBP"]),
        (["reddit.com"], ["ref", "ref_source", "rdt", "share_id", "ref_campaign"]),
        (["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.es", "amazon.it", "amazon.ca", "amazon.com.tr", "amazon.co.jp"],
         ["ascsubtag", "content-id", "crid", "dib", "dib_tag", "linkcode", "linkid", "pd_rd_i", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf", "pf_rd_i", "pf_rd_m", "pf_rd_p", "pf_rd_r", "pf_rd_s", "pf_rd_t", "psc", "qid", "ref_", "smid", "sprefix", "sr", "tag"]),
        (["aliexpress.com"], ["afsmartredirect", "aff_fcid", "aff_fsk", "btsid", "gatewayadapt", "sk", "terminal_id", "ws_ab_test"]),
        (["ebay.com"], ["_trkparms", "_trksid", "amdata", "campid", "customid", "hash", "mkcid", "mkevt", "mkrid", "toolid"]),
    ]

    private static let prefixes = ["utm_", "pf_rd_", "pd_rd_", "__cft__", "hsa_", "stm_"]

    static func removeTracking(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.percentEncodedQueryItems else { return url }
        let host = url.host?.lowercased() ?? ""
        let extra = bySite.first { $0.domains.contains { host == $0 || host.hasSuffix("." + $0) } }?.names.map { $0.lowercased() } ?? []
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !tracking.contains(name) && !extra.contains(name) && !prefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return url }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    // Sites that send every outgoing link through themselves, with the real one in a parameter. A host covers its
    // subdomains and a path covers what's below it.
    private static let wrappers: [(host: String, path: String, parameter: String)] = [
        ("google.com", "/url", "q"), ("google.com", "/url", "url"), ("google.com", "/imgres", "imgurl"),
        ("youtube.com", "/redirect", "q"),
        ("facebook.com", "/l.php", "u"), ("facebook.com", "/flx/warn", "u"), ("l.instagram.com", "/", "u"), ("l.threads.net", "/", "u"),
        ("linkedin.com", "/safety/go", "url"), ("linkedin.com", "/redir/redirect", "url"),
        ("safelinks.protection.outlook.com", "/", "url"), ("statics.teams.cdn.office.net", "/evergreen-assets/safelinks", "url"),
        ("slack-redir.net", "/link", "url"), ("steamcommunity.com", "/linkfilter", "url"), ("steamcommunity.com", "/linkfilter", "u"),
        ("out.reddit.com", "/", "url"), ("t.umblr.com", "/redirect", "z"), ("vk.com", "/away.php", "to"), ("ok.ru", "/dk", "st.link"),
        ("disq.us", "/url", "url"), ("deref-gmx.net", "/mail/client", "redirectUrl"), ("urldefense.proofpoint.com", "/v2/url", "u"),
        ("bing.com", "/ck/a", "u"), ("duckduckgo.com", "/l", "uddg"), ("nav.cx", "/", "url"),
    ]

    static func unwrap(_ url: URL) -> URL {
        var current = url
        // A wrapper can wrap a wrapper, but not forever.
        for _ in 0..<4 {
            guard let next = unwrappedOnce(current), next != current else { break }
            current = next
        }
        return current
    }

    private static func unwrappedOnce(_ url: URL) -> URL? {
        guard var host = url.host?.lowercased() else { return nil }
        if host == "href.li", let query = url.query { return httpURL(query) }
        if host == "urldefense.com", url.path.hasPrefix("/v3/__") { return proofpointV3(url) }
        // Google's country sites redirect the same way: www.google.co.uk/url
        if host.range(of: #"(^|\.)google\.[a-z.]+$"#, options: .regularExpression) != nil { host = "google.com" }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for wrapper in wrappers where host == wrapper.host || host.hasSuffix("." + wrapper.host) {
            guard url.path.lowercased().hasPrefix(wrapper.path.lowercased()),
                  let value = items.first(where: { $0.name == wrapper.parameter })?.value else { continue }
            if let target = decodedTarget(value, wrapper.host) { return target }
        }
        return nil
    }

    private static func decodedTarget(_ value: String, _ host: String) -> URL? {
        switch host {
        case "urldefense.proofpoint.com":
            return httpURL(value.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "%").removingPercentEncoding ?? "")
        case "bing.com":
            // Base64 of the real link, after a two-letter prefix.
            var text = String(value.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }.flatMap(httpURL)
        default:
            return httpURL(value)
        }
    }

    // https://urldefense.com/v3/__https://example.com/page__;!!token$ where a * stands for a character kept in the token,
    // so a link with one in it can't be recovered and stays wrapped.
    private static func proofpointV3(_ url: URL) -> URL? {
        let text = url.absoluteString
        guard let start = text.range(of: "/v3/__"), let end = text.range(of: "__;", range: start.upperBound..<text.endIndex) else { return nil }
        let inner = String(text[start.upperBound..<end.lowerBound])
        return inner.contains("*") ? nil : httpURL(inner)
    }

    static func httpURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static let shorteners: Set<String> = [
        "1url.com", "adf.ly", "amzn.eu", "amzn.to", "bit.do", "bit.ly", "bitly.com", "buff.ly", "cli.gs", "clck.ru", "cutt.ly", "dlvr.it",
        "fb.me", "git.io", "goo.gl", "g.co", "hubs.la", "ift.tt", "is.gd", "lc.chat", "lnkd.in", "mcaf.ee", "ow.ly", "pin.it", "qr.ae", "rb.gy",
        "rebrand.ly", "redd.it", "s.id", "shorturl.at", "snip.ly", "spoti.fi", "sptfy.com", "t.co", "t.ly", "tiny.cc", "tinyurl.com", "trib.al",
        "u.to", "v.gd", "vm.tiktok.com", "vt.tiktok.com", "wp.me", "x.co", "yhoo.it", "zpr.io",
    ]

    static func isShort(_ url: URL, extra: [String]) -> Bool {
        guard let host = url.host?.lowercased(), url.path.count > 1 else { return false }
        return shorteners.contains(host) || extra.contains { $0.lowercased() == host }
    }

    // A script sees the link as `url`, and what it returns replaces it. It can't hold up a link for long: on a timeout
    // or an error the link carries on as it was.
    static func runScript(_ script: String, on url: URL, source: String?) async -> URL {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return url }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL, Never>) in
            let finished = Once(continuation)
            // JavaScriptCore has no public way to stop a script, so a runaway one keeps its own thread until Gremlin quits.
            Thread.detachNewThread {
                let context = JSContext()
                context?.setObject(url.absoluteString, forKeyedSubscript: "url" as NSString)
                context?.setObject(source ?? "", forKeyedSubscript: "sourceApp" as NSString)
                let value = context?.evaluateScript("(function (url, sourceApp) {\n\(script)\n})(url, sourceApp)")
                var result = url
                if context?.exception != nil {
                    Log.write("Link script failed: \(context?.exception?.toString() ?? "")")
                } else if let value, value.isString, let text = value.toString(), let next = URL(string: text), next.scheme != nil {
                    result = next
                }
                finished.resume(result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                finished.resume(url)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<URL, Never>) {
            self.continuation = continuation
        }

        func resume(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(returning: url)
            continuation = nil
        }
    }
}

// Follows a short link only as far as the shortener's own redirects, so the page it points at never sees a request.
final class ShortLinkExpander: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let extra: [String]
    private let lock = NSLock()
    private var last: URL?

    private init(extra: [String]) {
        self.extra = extra
    }

    static func expand(_ url: URL, extra: [String]) async -> URL {
        let expander = ShortLinkExpander(extra: extra)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 2.5
        let session = URLSession(configuration: configuration, delegate: expander, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
        if let last = expander.result { return last }
        // Some shorteners turn HEAD away.
        request.httpMethod = "GET"
        _ = try? await session.data(for: request)
        return expander.result ?? url
    }

    private var result: URL? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url else { return completionHandler(nil) }
        lock.lock()
        last = next
        lock.unlock()
        completionHandler(LinkCleaner.isShort(next, extra: extra) ? request : nil)
    }
}

// Rules are also written by hand and pasted in, so anything left out takes its default.
extension LinkTarget {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        app = try values.decode(String.self, forKey: .app)
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName)
        isPrivate = try values.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }
}

extension LinkMatcher {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .domain
        value = try values.decode(String.self, forKey: .value)
    }
}

extension LinkRule {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        isOn = try values.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        target = try values.decodeIfPresent(LinkTarget.self, forKey: .target) ?? .prompt
        matchers = try values.decodeIfPresent([LinkMatcher].self, forKey: .matchers) ?? []
        sources = try values.decodeIfPresent([String].self, forKey: .sources) ?? []
        script = try values.decodeIfPresent(String.self, forKey: .script) ?? ""
    }
}
