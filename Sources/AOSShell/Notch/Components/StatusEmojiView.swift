import SwiftUI

// MARK: - StatusEmojiView
//
// AgentStatus → text-emoji mapping per notch-ui.md "AgentStatus → 颜文字映射".
// Three sizes:
//   - `.small`:  closed-bar variant, 16pt
//   - `.medium`: opened-panel variant, 32pt — sized to align with the
//                two-row "context + input" header.
//   - `.large`:  reserved for hero contexts, 64pt
// All glyphs are 2 chars wide so monospaced rendering keeps the slot a
// fixed pixel width across status transitions.
//
// `.working` is rendered as a `:/` ↔ `:\` heartbeat via TimelineView so the
// closed bar and the opened panel share the same animated thinking glyph.

struct StatusEmojiView: View {
    let status: AgentStatus
    let size: Size

    enum Size {
        case small, medium, large
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 16
        case .medium: return 32
        case .large: return 64
        }
    }

    private var weight: Font.Weight {
        size == .small ? .medium : .bold
    }

    var body: some View {
        Group {
            if status == .working {
                TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                    let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4)
                    Text(tick.isMultiple(of: 2) ? ":/" : ":\\")
                }
            } else {
                Text(staticText)
            }
        }
        .font(.system(size: fontSize, weight: weight, design: .monospaced))
        .foregroundStyle(.white)
        .accessibilityLabel(Text(verbatim: "Agent status: \(status)"))
    }

    private var staticText: String {
        switch status {
        case .idle: return ":)"
        case .listening: return ":o"
        case .working: return ":/" // unreachable — handled above
        case .done: return ":D"
        case .waiting: return ":?"
        case .error: return ":("
        }
    }
}
