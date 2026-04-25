import SwiftUI

// MARK: - StatusEmojiView
//
// AgentStatus → text-emoji mapping per notch-ui.md "AgentStatus → 颜文字映射".
// Two sizes:
//   - `large = false`: the closed-bar variant, 16pt
//   - `large = true`:  the opened-panel variant, 64pt
// Always monospaced so the different glyph widths (`:)` vs `>_<`) don't
// shift surrounding layout.

struct StatusEmojiView: View {
    let status: AgentStatus
    let large: Bool

    private var text: String {
        switch status {
        case .idle: return ":)"
        case .listening: return ":o"
        case .thinking: return ":/"
        case .working: return ">_<"
        case .done: return ":D"
        case .waiting: return ":?"
        case .error: return ":("
        }
    }

    var body: some View {
        Text(text)
            .font(
                large
                    ? .system(size: 64, weight: .bold, design: .monospaced)
                    : .system(size: 16, weight: .medium, design: .monospaced)
            )
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Agent status: \(status)"))
    }
}
