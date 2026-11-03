import GateLinkKit
import PhotosUI
import SwiftUI

/// Adds a 2FA account from a QR image (Photos or the clipboard) or from a
/// pasted otpauth:// URI or secret key.
struct AddAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var scanned: AccountDraft?
    @State private var photo: PhotosPickerItem?
    @State private var manualInput = ""
    @State private var name = ""
    @State private var username = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("From a QR code") {
                    if let scanned {
                        Label("Found \(scanned.account.issuer)\(scanned.account.label.isEmpty ? "" : " (\(scanned.account.label))")",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    PhotosPicker("Choose QR Image…", selection: $photo, matching: .images)
                    Button("Paste QR Image") { scanPasteboard() }
                }

                Section("Or enter it manually") {
                    TextField("otpauth://totp/… or JBSWY3DP…", text: $manualInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional), e.g. Company VPN", text: $name)
                }

                Section {
                    TextField("VPN username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The login name for the gateway. Defaults to the name in the QR code.")
                }

                if let error {
                    Section {
                        ErrorCallout(message: error)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Add 2FA Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(saving || (scanned == nil && manualInput.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)?.cgImage
                    else {
                        error = "Could not open that image."
                        return
                    }
                    scan { try QRCodeReader.otpAuthURI(in: image) }
                }
            }
        }
    }

    private func scanPasteboard() {
        guard let image = UIPasteboard.general.image?.cgImage else {
            error = "The clipboard does not contain an image."
            return
        }
        scan { try QRCodeReader.otpAuthURI(in: image) }
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
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
