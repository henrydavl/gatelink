import GateLinkKit
import SwiftUI

/// The current code with a countdown ring, or a masked placeholder.
struct CodeView: View {
    let totp: TOTP?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let totp {
                    Text(Self.grouped(totp.code(at: context.date)))
                        .font(.system(.title3, design: .monospaced))
                        .contentTransition(.numericText())
                    Countdown(remaining: totp.secondsRemaining(at: context.date), period: totp.period)
                } else {
                    Text("••• •••")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Code hidden")
                }
            }
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}

struct Countdown: View {
    let remaining: Int
    let period: Int

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(period))
                .stroke(remaining <= 5 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("\(remaining) seconds left")
    }
}

/// An error message in a soft red box, calmer than red text.
struct ErrorCallout: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}
