import SwiftUI

/// Shown the first time an AI feature is used with nothing connected. Leads
/// with Sign in with ChatGPT (no API key needed); API keys are one step away.
struct AISetupSheet: View {
    @ObservedObject private var chatGPT = ChatGPTAuth.shared
    @Environment(\.dismiss) private var dismiss
    @State private var hoveringSettings = false
    @State private var hoveringLater = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accent)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accent.opacity(0.12)))

            VStack(spacing: 6) {
                Text("Connect AI")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.ink)
                Text("AI alternatives and the Lab use your own AI account. Continue with ChatGPT to use the plan you already have.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ContinueWithChatGPTButton(busy: chatGPT.signingIn, fullWidth: true) { chatGPT.signIn() }

            if let error = chatGPT.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: Theme.cutStrike).opacity(1))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 4) {
                Text("Have an Anthropic or OpenAI API key?")
                    .foregroundStyle(Color.inkSecondary)
                SettingsLink { Text("Use it in Settings").underline(hoveringSettings) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
                    .onHover { hoveringSettings = $0 }
                    .pointingHandOnHover()
                    .simultaneousGesture(TapGesture().onEnded {
                        SettingsView.showAITab()
                        dismiss()
                    })
            }
            .font(.system(size: 11.5))

            Button("Not now") {
                chatGPT.cancelSignIn()
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(hoveringLater ? Color.ink : Color.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.ink.opacity(hoveringLater ? 0.07 : 0)))
            .contentShape(Capsule())
            .onHover { hoveringLater = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringLater)
            .keyboardShortcut(.cancelAction)
            .pointingHandOnHover()
        }
        .padding(28)
        .frame(width: 380)
        .background(Color.panel)
        .onChange(of: chatGPT.isConnected) { _, connected in
            if connected { dismiss() }
        }
    }
}

/// OpenAI's "Continue with ChatGPT" button: black, the white ChatGPT logo and
/// the approved label (per OpenAI's Sign in with ChatGPT UI guidelines).
struct ContinueWithChatGPTButton: View {
    var busy = false
    var fullWidth = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(Color.paper)
                } else {
                    Image("ChatGPTLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Text(busy ? "Finish signing in your browser…" : "Continue with ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 34)
            .background(
                // The page's ink: warm charcoal on light paper, warm white on dark.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.ink.opacity(hovering && !busy ? 0.86 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointingHandOnHover()
    }
}

/// "Using ChatGPT plan · Manage usage", shown when connected (per OpenAI's guidelines).
struct UsingChatGPTPlanLabel: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image("ChatGPTLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
            Text("Using ChatGPT plan")
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Link(destination: URL(string: "https://chatgpt.com/#settings")!) {
                Text("Manage usage").underline(hovering)
            }
            .onHover { hovering = $0 }
            .pointingHandOnHover()
        }
        .font(.caption)
    }
}
