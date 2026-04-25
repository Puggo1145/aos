import SwiftUI
import AOSOSSenseKit

// MARK: - OpenedPanelView
//
// Per notch-ui.md §"三态布局详细规格 → opened":
//   ┌──────────────────────────────────────────────────────────────┐
//   │  ┌───────────┐ │ ┌──────────────────────────────────────┐    │
//   │  │  emoji    │ │ │  context chips                       │    │
//   │  │  64pt     │ │ │  assistantText                       │    │
//   │  │           │ │ │  TextField                           │    │
//   │  └───────────┘ │ └──────────────────────────────────────┘    │
//   └──────────────────────────────────────────────────────────────┘
// Fixed `notchOpenedSize` layout with status and content columns inside
// the expanded notch silhouette.

struct OpenedPanelView: View {
    let viewModel: NotchViewModel
    let senseStore: SenseStore
    let agentService: AgentService

    /// Used by the panel-local override: when the input is focused, display
    /// `listening` instead of the service's actual status.
    private var displayStatus: AgentStatus {
        viewModel.inputFocused ? .listening : agentService.status
    }

    /// Top safe area equal to the physical notch height. The opened panel
    /// extends to the very top of the screen (`screenRect.maxY`), so any
    /// content rendered in `0..<deviceNotchRect.height` sits behind the
    /// hardware cutout. Reserve that band so chips/text/etc. always start
    /// below the cutout.
    private var topSafeInset: CGFloat {
        viewModel.deviceNotchRect.height
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column: large status emoji
            StatusEmojiView(status: displayStatus, large: true)
                .frame(width: 160)
                .padding(.leading, 24)
                .padding(.bottom, 24)

            // Right column
            VStack(alignment: .leading, spacing: 12) {
                ContextChipsView(senseStore: senseStore)

                // Error banner takes precedence over assistantText.
                if agentService.status == .error,
                   let msg = agentService.lastErrorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.12))
                        )
                }

                if !agentService.assistantText.isEmpty {
                    ScrollView {
                        Text(agentService.assistantText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 80)
                } else {
                    Spacer(minLength: 0)
                }

                AgentInputField(
                    senseStore: senseStore,
                    agentService: agentService,
                    inputFocused: Binding(
                        get: { viewModel.inputFocused },
                        set: { viewModel.inputFocused = $0 }
                    )
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, topSafeInset)
        .frame(width: viewModel.notchOpenedSize.width, height: viewModel.notchOpenedSize.height)
    }
}
