import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - AgentConversationView
//
// The conversation surface above the composer: scrolling history of past
// turns plus any session-level error banners. Owns the auto-follow-bottom
// state machine — all scroll/sentinel measurement lives here so the
// parent panel only sees a single self-contained view.
//
//   ┌─────────────────────────┐
//   │ ScrollView{             │
//   │   [icon] · prompt 1     │
//   │   :D  reply 1           │
//   │   [icon] · prompt 2     │
//   │   :O  reply 2 (stream)  │
//   │ }                       │
//   │ [error banners…]        │
//   └─────────────────────────┘
struct AgentConversationView: View {
    let viewModel: NotchViewModel
    let agentService: AgentService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var followBottom: Bool = true
    @State private var viewportHeight: CGFloat = 0
    @State private var bottomSentinelMaxY: CGFloat = 0
    @State private var prevContentHeight: CGFloat = 0
    @State private var prevBottomSentinelMaxY: CGFloat = 0
    @State private var followEvalPending: Bool = false
    @State private var lastObservedTurnCount: Int = 0

    /// Symmetric ±4pt band around the viewport bottom: re-attach when
    /// the sentinel sits within this slack of the bottom; detach when a
    /// user-driven scroll moves it more than this past content growth.
    private let atBottomSlack: CGFloat = 4
    private let userDetachThreshold: CGFloat = 4

    private var hasSession: Bool {
        viewModel.isAgentLoopActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasSession {
                history
            }
            errorBanners
        }
        .onChange(of: hasSession) { _, active in
            if !active { resetScrollState() }
        }
    }

    private func resetScrollState() {
        viewModel.historyContentHeight = 0
        followBottom = true
        viewportHeight = 0
        bottomSentinelMaxY = 0
        prevContentHeight = 0
        prevBottomSentinelMaxY = 0
        followEvalPending = false
        lastObservedTurnCount = 0
    }

    // MARK: - Error banners

    @ViewBuilder
    private var errorBanners: some View {
        // Boot-time session.create failure: explains why the composer
        // below is disabled.
        if let msg = agentService.sessionStore.bootError, !msg.isEmpty {
            errorBanner(msg)
        }
        // Session-action failures (create / activate / list refresh).
        if let actionError = agentService.sessionStore.lastActionError {
            dismissibleErrorBanner(actionError)
        }
        // Submit-time errors that have no per-turn slot (e.g. payload
        // exceeded the RPC line cap).
        if let msg = agentService.lastErrorMessage, !msg.isEmpty {
            errorBanner(msg)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.12))
            )
    }

    private func dismissibleErrorBanner(_ actionError: SessionActionError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(actionError.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                agentService.sessionStore.setActionError(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .notchForeground(.secondary)
            }
            .buttonStyle(.notchPressable)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.12))
        )
    }

    // MARK: - History

    /// Conversation history. Plain VStack (no LazyVStack) so each row
    /// reports its real height; `scrollTo` then lands precisely and the
    /// natural-height preference up to the viewmodel is the truth.
    ///
    /// Scroll behaviour is gated on `followBottom` (auto-snap to bottom
    /// on growth), which the user toggles by scrolling up/down. Detect
    /// the toggle via a 1pt sentinel at the bottom of content reporting
    /// its `maxY` in the ScrollView's coordinate space — a sentinel is
    /// required because a `.background` GeometryReader on the VStack
    /// only refires on size changes, not on pure scroll moves.
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Outer `spacing: 0` isolates the sentinel from the
                // inner 20pt turn spacing so the sentinel contributes
                // only its own 1pt to `historyContentHeight`.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(agentService.turns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .identity
                                ))
                        }
                    }
                    // Keyed on `count` so streaming tokens inside an
                    // existing turn don't trigger the insert transition.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: agentService.turns.count)

                    Color.clear
                        .frame(height: 1)
                        .id(historyBottomAnchor)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: HistoryBottomMaxYKey.self,
                                    value: geo.frame(in: .named(historyViewportSpace)).maxY
                                )
                            }
                        )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HistoryHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: historyViewportSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: HistoryViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onAppear {
                lastObservedTurnCount = agentService.turns.count
                guard let lastID = agentService.turns.last?.id else { return }
                followBottom = true
                Task { @MainActor in
                    await Task.yield()
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onPreferenceChange(HistoryViewportHeightKey.self) { h in
                viewportHeight = h.rounded()
                scheduleFollowEval()
            }
            .onPreferenceChange(HistoryHeightKey.self) { h in
                handleHistoryHeightChange(h, proxy: proxy)
            }
            .onPreferenceChange(HistoryBottomMaxYKey.self) { y in
                bottomSentinelMaxY = y.rounded()
                scheduleFollowEval()
            }
        }
    }

    // MARK: - Auto-follow-bottom state machine

    private func handleHistoryHeightChange(_ rawHeight: CGFloat, proxy: ScrollViewProxy) {
        let rounded = rawHeight.rounded()
        guard viewModel.historyContentHeight != rounded else { return }
        let didGrow = rounded > viewModel.historyContentHeight
        let countNow = agentService.turns.count
        let countGrew = countNow > lastObservedTurnCount
        lastObservedTurnCount = countNow
        let availableViewport = viewModel.notchOpenedMaxHeight
            - viewModel.openedContentVerticalChrome
            - viewModel.composerContentHeight
        let wasOverflowing = viewModel.historyContentHeight > availableViewport
        viewModel.historyContentHeight = rounded
        let nowOverflowing = rounded > availableViewport
        // Skip when content still fits — the panel grows downward
        // naturally and a scrollTo would bottom-pin the ScrollView,
        // producing a per-line bounce against the `.notchHeight`
        // animation.
        //
        // Skip when growth isn't a new turn and the last turn is
        // settled — that's the user expanding a ThinkingView /
        // ToolCallView, snapping would push the row they just opened
        // out of view.
        guard didGrow, followBottom, nowOverflowing,
              countGrew || isLastTurnLive else { return }
        // Animate when a new turn appeared or content just crossed
        // the overflow threshold (one large translation either way).
        // Snap instantly for per-token streaming growth, otherwise
        // each token would bounce.
        if (countGrew || !wasOverflowing) && !reduceMotion {
            Task { @MainActor in
                await Task.yield()
                withAnimation(.smooth(duration: 0.32)) {
                    proxy.scrollTo(historyBottomAnchor, anchor: .bottom)
                }
            }
        } else {
            snapToBottom(proxy: proxy)
        }
    }

    /// Coalesce evaluation onto the next MainActor hop so the height
    /// and sentinel preferences for the same layout pass are both
    /// observed before judging — SwiftUI delivers the inner sentinel
    /// preference before the outer height, and without batching the
    /// evaluator sees a stale content height.
    private func scheduleFollowEval() {
        guard !followEvalPending else { return }
        followEvalPending = true
        Task { @MainActor in
            await Task.yield()
            followEvalPending = false
            evaluateFollowState()
        }
    }

    /// `userDelta = Δsentinel − Δcontent` isolates user-driven scroll
    /// from layout-driven sentinel motion: detach when it crosses
    /// `userDetachThreshold` upward, re-attach when the sentinel sits
    /// within `atBottomSlack` of the viewport bottom.
    private func evaluateFollowState() {
        guard viewportHeight > 0 else { return }
        let currentContentHeight = viewModel.historyContentHeight
        let dy = bottomSentinelMaxY - prevBottomSentinelMaxY
        let dh = currentContentHeight - prevContentHeight
        // `max(0, dh)` so a content shrink doesn't masquerade as a fake
        // user scroll.
        let userDelta = dy - max(0, dh)

        if followBottom && userDelta > userDetachThreshold {
            followBottom = false
        }

        let isAtBottom = bottomSentinelMaxY <= viewportHeight + atBottomSlack
        if isAtBottom && !followBottom {
            followBottom = true
        }

        prevContentHeight = currentContentHeight
        prevBottomSentinelMaxY = bottomSentinelMaxY
    }

    /// True while the last turn is still producing output (thinking,
    /// awaiting a tool result, or streaming tokens). Used to
    /// distinguish live growth from a user-driven row expansion.
    private var isLastTurnLive: Bool {
        guard let last = agentService.turns.last else { return false }
        switch last.status {
        case .working, .waiting, .listening:
            return true
        case .done, .idle, .error:
            return false
        }
    }

    private func snapToBottom(proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                proxy.scrollTo(historyBottomAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: - Turn rendering

    /// One historical turn: compressed header (app icon + prompt) over
    /// an emoji-prefixed reply block, plus an optional error banner.
    private func turnRow(_ turn: ConversationTurn) -> some View {
        // O(1) segment → tool-call resolution; matters on tool-heavy turns
        // because every streaming token redraws every visible row.
        let toolCallById: [String: ToolCallRecord] = Dictionary(
            uniqueKeysWithValues: turn.toolCalls.map { ($0.id, $0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon = turn.context.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                }
                PromptWithChipsView(
                    prompt: turn.prompt,
                    clipboardLabels: turn.context.clipboardLabels
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 8) {
                turnEmojiView(turn)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    // Segments render in emission order so thinking / tool
                    // calls / reply chunks interleave as the model produced
                    // them. IDs are stable so SwiftUI preserves per-row
                    // state across redraws.
                    ForEach(turn.segments) { segment in
                        segmentView(segment, toolCallById: toolCallById)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if turn.status == .error, let msg = turn.errorMessage, !msg.isEmpty {
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
        }
    }

    @ViewBuilder
    private func segmentView(
        _ segment: TurnSegment,
        toolCallById: [String: ToolCallRecord]
    ) -> some View {
        switch segment {
        case .thinking(let s):
            ThinkingView(
                thinking: s.text,
                startedAt: s.startedAt,
                endedAt: s.endedAt,
                isCurrent: s.isOpenForAppend
            )
        case .toolCall(let id):
            if let record = toolCallById[id] {
                ToolCallView(record: record)
            }
        case .reply(let s):
            if !s.text.isEmpty {
                ReplyMarkdownView(text: s.text)
            }
        }
    }

    /// Per-turn emoji driven by the turn's own status. While the turn
    /// is thinking with no tokens yet, animate a `:/` ↔ `:\` heartbeat.
    @ViewBuilder
    private func turnEmojiView(_ turn: ConversationTurn) -> some View {
        if turn.status == .working && turn.reply.isEmpty && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4)
                Text(tick.isMultiple(of: 2) ? ":/" : ":\\")
            }
        } else {
            Text(turnEmoji(turn))
        }
    }

    private func turnEmoji(_ turn: ConversationTurn) -> String {
        switch turn.status {
        case .error: return ":("
        case .working: return turn.reply.isEmpty ? ":/" : ":O"
        case .waiting: return ":?"
        case .listening: return ":o"
        case .done, .idle:
            return turn.reply.isEmpty ? ":|" : ":D"
        }
    }
}

private let historyBottomAnchor = "history.bottom"
private let historyViewportSpace = "history.viewport"

private struct HistoryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HistoryViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HistoryBottomMaxYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
