import SwiftUI

// What the window and the shelf show. AppDelegate fills it in from the features and carries out its actions.
@MainActor
final class MenuModel: ObservableObject {
    enum Action: Equatable {
        case record(audioOnly: Bool)
        case stopRecording
        case open(URL)
        case openTranscript(URL)
        case dismissTranscript
        case fix(URL)
        case dismissProblem
        case showRecordings
        case grabText
        case pickColor
        case plainPaste
        case fixFocus
        case keepAwake(Int)
        case toggleSidecar
        case setSwitch(String, Bool)
        case resetUniversalControl(UniversalControlWatcher.Target)
        case startPairing
        case stopPairing
        case unpair
        case restart(Int)
        case restartAll
        case setLogin(Bool)
        case setLanguage(String?)
        case openWindow(Module?)
        case syncMeetings
        case signInToDrive(id: String, secret: String)
        case signInToDriveWithClipboard
        case signInToDriveAgain
        case cancelDriveSignIn
        case signOutOfDrive
        case forgetDriveClient
        case recordScreen(UInt32)
        case logInToClaude
        case summarize(URL)
        case quit
    }

    struct Recording: Equatable {
        var started: Date
        var audioOnly: Bool
        var hearing: Bool
        var screen: UInt32?
    }

    struct Screen: Equatable, Identifiable {
        let id: UInt32
        let name: String
    }

    struct Banner: Equatable, Identifiable {
        enum Kind {
            case working
            case done
            case problem
        }

        var id: String
        var kind: Kind
        var symbol = "exclamationmark"
        var title: String
        var detail: String
        var button: String?
        var action: Action?
        var dismiss: Action?
    }

    struct IPad: Equatable {
        enum State {
            case nearby
            case connecting
            case disconnecting
            case connected
            case away
        }

        var name: String
        var state: State
        var seen: Date?
    }

    struct Watcher: Equatable {
        var isOn = false
        var tone = Tone.off
        var status = ""
        var detail = ""
        var lastReset = ""
    }

    enum Pairing: Equatable {
        case unpaired
        case pairing
        case paired(name: String, status: String)
    }

    static let awakeStops = ["Off", "30m", "1h", "2h", "4h", "∞"]
    static let reachable = "reachable"
    static let unreachable = "not reachable"
    static let languages: [(name: String, code: String?)] = [
        ("Automatic", nil), ("English", "en"), ("Turkish", "tr"), ("German", "de"), ("French", "fr"), ("Spanish", "es"),
    ]

    @Published var recording: Recording?
    @Published var starting = false
    @Published var banners: [Banner] = []
    @Published var notesProgress: MeetingNotes.Progress?
    @Published var awakeStop = 0
    @Published var awakeText = "Off"
    @Published var awakeOthers: [String] = []
    @Published var ipad: IPad?
    @Published var watcher = Watcher()
    @Published var pairing = Pairing.unpaired
    @Published var thisMac = "This Mac"
    @Published var switches: [String: Bool] = [:]
    @Published var accessibility = false
    @Published var login = false
    @Published var language: String?
    @Published var restarted: Set<Int> = []
    @Published var confirmRestartAll = false
    @Published var sync = MeetingSync.Status()
    @Published var screens: [Screen] = []
    @Published var claudeLoggedOut = false

    var perform: (Action) -> Void = { _ in }
    let links: Links
    let drives: Drives
    let displays: Displays
    let scrolling: ScrollDirection
    let vpn: VPN
    let cables: Cables

    init(links: Links, drives: Drives, displays: Displays, scrolling: ScrollDirection, vpn: VPN, cables: Cables) {
        self.links = links
        self.drives = drives
        self.displays = displays
        self.scrolling = scrolling
        self.vpn = vpn
        self.cables = cables
    }
}

// The settings keys, shared by the window, the shelf and the features they switch.
enum AppSwitch {
    static let autoFixFocus = "autoFixFocus"
    static let notificationCenterWatchdog = "notificationCenterWatchdog"
    static let universalControlWatcher = "universalControlWatcher"
    static let offerToRecordCalls = "offerToRecordCalls"
}
