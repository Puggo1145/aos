import SwiftUI
import AOSOSSenseKit
import AOSRPCSchema

// MARK: - AgentInputField
//
// Per notch-ui.md §"输入区". A transparent, borderless TextField that on
// `.onSubmit` projects the live `SenseContext` to a `CitedContext` and
// fires `agentService.submit(...)`. Focus state is propagated to the
// view-model so the displayed status emoji can flip to `:o` (listening)
// while the user is composing — without polluting `AgentService.status`.

struct AgentInputField: View {
    let senseStore: SenseStore
    let agentService: AgentService
    @Binding var inputFocused: Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tell me what you want to do", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($focused)
            .onChange(of: focused) { _, newValue in
                inputFocused = newValue
            }
            .onSubmit {
                let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { return }
                let cited = CitedContextProjection.project(from: senseStore.context)
                let promptCopy = prompt
                Task { await agentService.submit(prompt: promptCopy, citedContext: cited) }
                text = ""
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.clear)
            .accessibilityLabel(Text("Prompt input"))
    }
}
