#if os(macOS)
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Settings ▸ Downloads ▸ Remote devices. Off until the person turns it on; never shows a token, a key or a secret other than the short-lived invitation they are about to give a device.
struct RemoteDevicesSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { RemoteDevicesContent(remote: model.automation.remote) }
}

private struct RemoteDevicesContent: View {
    @ObservedObject var remote: RemoteAccessController
    @ObservedObject private var devices: RemoteDeviceStore
    @ObservedObject private var pairing: PairingManager
    @State private var typedCode = ""
    @State private var message: String?
    @State private var showLog = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(remote: RemoteAccessController) {
        self.remote = remote
        _devices = ObservedObject(wrappedValue: remote.devices)
        _pairing = ObservedObject(wrappedValue: remote.pairing)
    }

    var body: some View {
        Section("Remote devices") {
            Toggle("Allow paired devices to manage downloads", isOn: Binding(get: { remote.enabled }, set: { on in Task { await remote.setEnabled(on) } }))
            Label(remote.state.title, systemImage: symbol).foregroundStyle(color)
            if case .unsupported(let why) = remote.state { Text(why).font(.caption).foregroundStyle(.secondary) }
            if case .error(let why) = remote.state { Text(why).font(.caption).foregroundStyle(.orange) }
            Text("Off by default. A device must be paired here first, can do only what you allow, and can be removed at any time. Downloads you start or approve on this Mac are never changed by a device disconnecting. Nothing is reachable from the internet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if remote.enabled { pairingArea }
            if remote.enabled || !devices.devices.isEmpty { deviceList }
            DisclosureGroup("Connection log", isExpanded: $showLog) {
                if remote.log.isEmpty { Text("Nothing yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(remote.log.suffix(20).enumerated()), id: \.offset) { _, line in Text(line).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled) }
            }
        }
        .onReceive(tick) { now = $0; pairing.expireIfNeeded() }
    }

    @ViewBuilder private var pairingArea: some View {
        if let pending = pairing.pending {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(pending.deviceName)” wants to pair").font(.system(size: 13, weight: .semibold))
                Text("It would be able to: " + pending.scopes.map(Self.describe).sorted().joined(separator: ", ")).font(.caption)
                Text("Type the six digits the device is showing. If it shows no digits, or you did not start this, decline.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("000000", text: $typedCode).frame(width: 90).font(.system(.body, design: .monospaced))
                    Button("Approve") { approve(pending) }.disabled(typedCode.filter(\.isNumber).count != 6)
                    Button("Decline") { pairing.reject(pairingID: pending.pairingID); typedCode = "" }
                }
                if pending.wrongAttempts > 0 { Text("\(pending.wrongAttempts) wrong attempt\(pending.wrongAttempts == 1 ? "" : "s").").font(.caption).foregroundStyle(.orange) }
            }
        } else if let invitation = pairing.invitation {
            VStack(alignment: .leading, spacing: 6) {
                if let image = Self.qr(invitation.qrPayload) { Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: 150, height: 150).accessibilityLabel("Pairing code") }
                Text(invitation.readableCode).font(.system(.caption, design: .monospaced)).textSelection(.disabled)
                Text(remaining(invitation)).font(.caption).foregroundStyle(.secondary)
                Button("Cancel Pairing") { pairing.cancel(); typedCode = "" }
            }
        } else if pairing.awaitingCollection {
            Text("Approved. Waiting for the device to collect its credentials…").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Add Device…") {
                if case .failure(let e) = pairing.createInvitation() { message = e.message } else { message = nil }
            }
        }
        if let message { Text(message).font(.caption).foregroundStyle(.orange) }
    }

    private func approve(_ pending: PairingPending) {
        switch pairing.approve(pairingID: pending.pairingID, typedCode: typedCode) {
        case .success: message = "Paired. The device can now collect its credentials."; typedCode = ""
        case .failure(let e): message = e.message; if case .tooManyAttempts = e { typedCode = "" }
        }
    }

    private func remaining(_ i: PairingInvitation) -> String {
        let s = max(0, Int(i.expiresAt.timeIntervalSince(now)))
        return s == 0 ? "Expired" : "Expires in \(s / 60):\(String(format: "%02d", s % 60)). Works once."
    }

    private var deviceList: some View {
        ForEach(devices.devices) { d in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(d.name).font(.system(size: 13, weight: .medium))
                    Text(d.isActive ? "" : "Revoked").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if d.isActive { Button("Revoke") { remote.revoke(d.id) } }
                    Button("Remove") { remote.remove(d.id) }
                }
                let scopes = remote.automation.clients.clients.first { $0.id == d.id }?.scopes ?? []
                Text("Paired " + d.enrolledAt.formatted(date: .abbreviated, time: .omitted) + " · " + (d.lastConnectedAt.map { "last connected " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "never connected") + (scopes.isEmpty ? "" : " · " + scopes.map(Self.describe).sorted().joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch remote.state { case .disabled: "power"; case .unsupported: "exclamationmark.triangle"; case .ready, .disconnected: "checkmark.circle"; case .pairing: "qrcode"; case .connected: "iphone.and.arrow.forward"; case .permissionRequired: "lock"; case .error: "xmark.octagon" }
    }
    private var color: Color {
        switch remote.state { case .unsupported, .error, .permissionRequired: .orange; case .connected, .ready: .green; default: .secondary }
    }

    static func describe(_ scope: AutomationScope) -> String {
        switch scope {
        case .downloadsRead: "see downloads"
        case .downloadsCreate: "propose downloads"
        case .downloadsControl: "pause, resume, cancel and retry"
        case .downloadsFiles: "delete finished files"
        case .queuesRead: "see the queue"
        case .queuesControl: "hold the queue"
        case .settingsRead: "read download settings"
        }
    }

    /// The QR image is made on demand and never saved or copied anywhere.
    static func qr(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#endif
