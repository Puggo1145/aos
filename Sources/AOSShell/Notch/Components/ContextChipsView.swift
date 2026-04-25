import SwiftUI
import AOSOSSenseKit

// MARK: - ContextChipsView
//
// Pure SwiftUI projection of `SenseStore.context` per notch-ui.md
// §"Context chips 区契约":
//
//   chips = behaviors[] + windowChip
//
// In Stage 0 the `behaviors` list is always empty (no GeneralProbe / no
// adapters registered yet), so the only rendered chip is the derived
// window chip "<App> · <Window Title>". This is the design's degraded
// path — when later stages start producing behaviors the row populates
// without code change.

struct ContextChipsView: View {
    let senseStore: SenseStore

    private var windowChipSummary: String? {
        guard let app = senseStore.context.app else { return nil }
        if let title = senseStore.context.window?.title, !title.isEmpty {
            return "\(app.name) · \(title)"
        }
        return app.name
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(senseStore.context.behaviors, id: \.id) { envelope in
                    chip(text: envelope.displaySummary)
                }
                if let summary = windowChipSummary {
                    chip(text: summary)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func chip(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .lineLimit(1)
    }
}
