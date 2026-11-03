import AppKit
import GateLinkKit
import SwiftUI
import UniformTypeIdentifiers

/// Adds a 2FA account from a QR image or from a pasted URI / secret key.
struct AddAccountView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var scanned: AccountDraft?
    @State private var manualInput = ""
    @State private var name = ""
    @State private var username = ""
    @State private var error: String?
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add 2FA Account")
                .font(.title2.bold())

            GroupBox {
                qrSection
                    .padding(8)
            } label: {
                Text("From a QR code")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("otpauth:// URI or secret key", text: $manualInput, prompt: Text("otpauth://totp/… or JBSWY3DP…"))
                    TextField("Name", text: $name, prompt: Text("Name (optional), e.g. Company VPN"))
                }
                .textFieldStyle(.roundedBorder)
                .padding(8)
            } label: {
                Text("Or enter it manually")
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("VPN username", text: $username, prompt: Text("VPN username"))
                    .textFieldStyle(.roundedBorder)
                Text("The login name for the gateway. Defaults to the name in the QR code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (scanned == nil && manualInput.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): scan { try QRCodeReader.otpAuthURI(inImageAt: url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private var qrSection: some View {
        VStack(spacing: 10) {
            if let scanned {
                Label("Found \(scanned.account.issuer)\(scanned.account.label.isEmpty ? "" : " (\(scanned.account.label))")",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Drop a QR code image here", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Image…") { importing = true }
                Button("Paste Image") { scanPasteboard() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            scan { try QRCodeReader.otpAuthURI(inImageAt: url) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func scanPasteboard() {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            error = "The clipboard does not contain an image."
            return
        }
        scan { try QRCodeReader.otpAuthURI(in: cgImage) }
    }

    private func scan(_ read: () throws -> OTPAuthURI) {
        do {
            let draft = AccountDraft(uri: try read())
            scanned = draft
            manualInput = ""
            if username.isEmpty { username = draft.account.username }
            error = nil
        } catch {
            scanned = nil
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            var draft: AccountDraft
            if !manualInput.trimmingCharacters(in: .whitespaces).isEmpty {
                draft = try AccountDraft.fromManualInput(manualInput, issuer: name, username: username)
            } else if let scanned {
                draft = scanned
                let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { draft.account.username = trimmed }
                let issuer = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !issuer.isEmpty { draft.account.issuer = issuer }
            } else {
                return
            }
            guard try await model.add(draft) else {
                error = "Unlock cancelled; the account was not saved."
                return
            }
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func close() {
        scanned = nil
        manualInput = ""
        name = ""
        username = ""
        error = nil
        dismissWindow(id: WindowID.addAccount)
    }
}
