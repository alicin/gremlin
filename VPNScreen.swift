import SwiftUI

private typealias Row = DevicesParts.Row

// VPN in the window: Tailscale with its devices on the left, the WireGuard tunnels and any other VPN on the right.
struct VPNScreen: View {
    @EnvironmentObject private var vpn: VPN

    private var showsTailscale: Bool { vpn.tailscaleInstalled || vpn.tailscaleTunnel != nil }

    var body: some View {
        let on = vpn.others.filter { $0.state == .on }.count + (vpn.tailscaleOn ? 1 : 0)
        ScreenCard(module: .vpn) {
            HeaderNote(text: on == 0 ? "All off" : "\(on) on", symbol: on == 0 ? "lock.open.fill" : "lock.shield.fill")
        } content: {
            VStack(spacing: 14) {
                if let problem = vpn.problem { ProblemLine(text: problem) { vpn.dismissProblem() } }
                HStack(alignment: .top, spacing: 18) {
                    if showsTailscale {
                        TailscalePanel().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    VStack(spacing: 14) {
                        TunnelsWell()
                        MenuBarTip()
                        Spacer(minLength: 0)
                    }
                    .frame(width: showsTailscale ? 330 : nil)
                    .frame(maxWidth: showsTailscale ? nil : .infinity)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                vpn.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }
}

private struct ProblemLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.coral)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.coral).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("OK", action: dismiss).buttonStyle(CapsuleButton(neutral: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.coral.opacity(0.12)))
    }
}

private struct TailscalePanel: View {
    @EnvironmentObject private var vpn: VPN
    @StateObject private var copied = Box<String?>(nil)

    var body: some View {
        let state = vpn.tailscale
        let on = vpn.tailscaleOn
        Well(padding: 18, fill: true) {
            HStack(spacing: 12) {
                IconTile(symbol: "point.3.filled.connected.trianglepath.dotted", tint: on ? Palette.ocean : Palette.slate, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(status).font(.system(size: 12.5)).foregroundStyle(state?.needsLogin == true ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 8)
                if vpn.tailscaleBusy {
                    DevicesParts.Spinner(tint: Palette.ocean, size: 20, line: 2.5)
                } else if state?.needsLogin == true {
                    Button("Log In") { vpn.setTailscale(true) }.buttonStyle(CapsuleButton(tint: Palette.ocean))
                } else {
                    ToggleSwitch(isOn: on, tint: Palette.ocean, label: "Tailscale") { vpn.setTailscale(!on) }
                }
            }
            if let state, on {
                VStack(spacing: 12) {
                    Row(symbol: "laptopcomputer", tint: Palette.ocean, title: "This Mac", detail: state.name) {
                        if let address = state.address { CopyChip(text: address, copied: $copied.value) { vpn.copy(address) } }
                    }
                    if !state.exitNodes.isEmpty || state.exitNode != nil {
                        Row(symbol: "arrow.triangle.branch", tint: Palette.ocean, title: "Exit node",
                            detail: state.exitNode.map { "Internet traffic goes through \($0.name)" } ?? "Internet traffic goes out directly") {
                            ExitNodeMenu(state: state)
                        }
                    }
                }
                .padding(.top, 6)
                ForEach(state.health.prefix(2), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
                }
                peers(state)
            } else {
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Open Tailscale") { NSWorkspace.shared.open(VPN.tailscaleApp) }
                    .buttonStyle(CapsuleButton(neutral: true))
                    .help("Log in, switch accounts or change Tailscale's own settings")
            }
        }
    }

    private var status: String {
        guard vpn.tailscaleInstalled else { return "The Tailscale app isn't installed" }
        guard let state = vpn.tailscale else { return vpn.tailscaleOn ? "Connected" : "Off" }
        if state.needsLogin { return "Needs you to log in" }
        guard vpn.tailscaleOn else { return state.backend == "Starting" ? "Starting…" : "Off" }
        let online = state.peers.filter(\.online).count
        return "Connected · \(online) of \(state.peers.count) devices online"
    }

    private func peers(_ state: TailscaleState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DevicesParts.Heading(title: "Devices") {
                Text("Click to copy the IP").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(state.peers) { PeerRow(peer: $0, copied: $copied.value) }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct PeerRow: View {
    let peer: TailscaleState.Peer
    @Binding var copied: String?
    @EnvironmentObject private var vpn: VPN
    @StateObject private var hovering = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button {
            guard let address = peer.address else { return }
            vpn.copy(address)
            CopyChip.flash(address, into: $copied)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: peer.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(peer.online ? AnyShapeStyle(Ink.ocean) : AnyShapeStyle(.tertiary))
                    .frame(width: 22)
                Text(peer.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if peer.exitNode {
                    Text("exit node").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Ink.ocean)
                        .padding(.horizontal, 6).frame(height: 17).background(Capsule().fill(Palette.ocean.opacity(0.15)))
                }
                Spacer(minLength: 8)
                if copied == peer.address, peer.address != nil {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.ocean)
                } else if let address = peer.address {
                    Text(address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                Circle().fill(peer.online ? Palette.good : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(shape.fill(.primary.opacity(hovering.value ? 0.06 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help(peer.online ? "\(peer.dnsName ?? peer.name) · online" : "\(peer.dnsName ?? peer.name) · offline")
        .contextMenu {
            if let address = peer.address { Button("Copy IP Address") { vpn.copy(address) } }
            if let name = peer.dnsName { Button("Copy Name") { vpn.copy(name) } }
        }
    }
}

private struct CopyChip: View {
    let text: String
    @Binding var copied: String?
    let action: () -> Void

    var body: some View {
        Button {
            action()
            Self.flash(text, into: $copied)
        } label: {
            HStack(spacing: 5) {
                Text(copied == text ? "Copied" : text).font(.system(size: 12, design: copied == text ? .default : .monospaced))
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Ink.ocean)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Palette.ocean.opacity(0.12)))
        }
        .buttonStyle(PressStyle())
        .help("Copy \(text)")
    }

    static func flash(_ text: String, into copied: Binding<String?>) {
        copied.wrappedValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copied.wrappedValue == text { copied.wrappedValue = nil }
        }
    }
}

private struct ExitNodeMenu: View {
    let state: TailscaleState
    @EnvironmentObject private var vpn: VPN

    var body: some View {
        Menu {
            Button("None") { vpn.useExitNode(nil) }
            Divider()
            ForEach(state.exitNodes) { peer in
                Button(peer.online ? peer.name : "\(peer.name) (offline)") { vpn.useExitNode(peer) }
                    .disabled(!peer.online)
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.exitNode?.name ?? "None")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(CapsuleButton(neutral: true))
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct TunnelsWell: View {
    @EnvironmentObject private var vpn: VPN

    var body: some View {
        let wireguard = vpn.others.filter { $0.app == .wireguard }
        let other = vpn.others.filter { $0.app == .other }
        Well {
            DevicesParts.Heading(title: "WireGuard") {
                if FileManager.default.fileExists(atPath: VPN.wireGuardApp.path) {
                    Button { NSWorkspace.shared.open(VPN.wireGuardApp) } label: {
                        HStack(spacing: 3) {
                            Text("Manage")
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.ocean)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add or edit tunnels in the WireGuard app")
                }
            }
            VStack(spacing: 14) {
                if wireguard.isEmpty {
                    Text("No WireGuard tunnels. Add one in the WireGuard app and it shows up here.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(wireguard) { TunnelRow(tunnel: $0) }
            }
            if !other.isEmpty {
                DevicesParts.Heading(title: "Other VPNs") { EmptyView() }.padding(.top, 6)
                VStack(spacing: 14) {
                    ForEach(other) { TunnelRow(tunnel: $0) }
                }
            }
        }
    }
}

private struct TunnelRow: View {
    let tunnel: VPNTunnel
    @EnvironmentObject private var vpn: VPN

    var body: some View {
        Row(symbol: tunnel.app == .wireguard ? "lock.shield.fill" : "network.badge.shield.half.filled",
            tint: tunnel.state == .on ? Palette.ocean : Palette.slate, title: tunnel.name, detail: tunnel.text) {
            if tunnel.busy {
                DevicesParts.Spinner(tint: Palette.ocean, size: 18, line: 2.25)
            } else {
                ToggleSwitch(isOn: tunnel.state == .on, tint: Palette.ocean, label: tunnel.name) { vpn.toggle(tunnel) }
            }
        }
        .animation(Motion.snappy, value: tunnel.state)
    }
}

private struct MenuBarTip: View {
    var body: some View {
        Well(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "menubar.rectangle", tint: Palette.slate, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hide their menu bar icons").font(.system(size: 13.5, weight: .semibold))
                    Text("Tailscale and WireGuard keep running with their icons hidden. Turn them off under Menu Bar in System Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Menu Bar Settings") { NSWorkspace.shared.open(VPN.menuBarSettings) }
                        .buttonStyle(CapsuleButton(neutral: true))
                        .padding(.top, 4)
                }
            }
        }
    }
}
