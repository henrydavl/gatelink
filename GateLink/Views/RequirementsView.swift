import GateLinkKit
import SwiftUI

/// What GateLink needs to connect, with a fix for anything missing.
struct RequirementsView: View {
    let model: AppModel
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Requirements")
                .font(.title2.bold())

            if model.requirements.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(model.requirements) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.isMet ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.isMet ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let fix = item.fix {
                            Text(fix)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack {
                Button("Remove Tunnel Helper…") { Task { await model.uninstallHelper() } }
                    .help("Removes /usr/local/libexec/gatelink and /etc/sudoers.d/gatelink")
                Spacer()
                Button("Check Again") { Task { await check() } }
                    .disabled(checking)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await check() }
    }

    private func check() async {
        checking = true
        await model.refreshRequirements()
        checking = false
    }
}
