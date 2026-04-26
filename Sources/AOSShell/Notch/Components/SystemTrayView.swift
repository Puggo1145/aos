import SwiftUI

// MARK: - SystemTrayView
//
// The drawer that pokes out below the main panel when there are pending
// system notices (permission gap, missing provider, config-corruption).
//
// Visual contract: this view paints NO surface of its own — the parent
// NotchView paints a single black silhouette spanning main panel + tray as
// one shape, so the tray reads as a downward extension of the notch rather
// than a separate card. This view contributes only the rows.
//
// Animation contract: collapsed/expanded transitions must NOT swap view
// structure (no `if expanded { A } else { B }` Group switch), because the
// resulting `.opacity` + insertion would read as a side panel sliding in
// from the right. Instead we always render every row in one VStack; the
// parent caps the visible height via `.frame(height:)` + `.clipShape`, so
// rows reveal/conceal purely by the drawer's animated height change.
// The chevron lives inside the first row's HStack (same layout in both
// states) and only its glyph flips on toggle.

struct SystemTrayView: View {
    let viewModel: NotchViewModel

    private var notices: [SystemNotice] { viewModel.trayNotices }
    private var hasMultiple: Bool { notices.count > 1 }

    @ViewBuilder
    var body: some View {
        if notices.isEmpty {
            EmptyView()
        } else {
            // ScrollView so the very rare case of >9 notices stays usable
            // when the drawer hits its 240pt ceiling. Disabled when the
            // drawer is collapsed so accidental scrolls don't reveal
            // hidden rows past the clipped frame.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        noticeRow(notices[0])
                        if hasMultiple { chevronButton }
                    }
                    ForEach(notices.dropFirst()) { noticeRow($0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TrayHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
            }
            .scrollDisabled(!viewModel.trayExpanded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onPreferenceChange(TrayHeightKey.self) { h in
                viewModel.trayContentHeight = h
            }
        }
    }

    // MARK: - Rows

    private func noticeRow(_ notice: SystemNotice) -> some View {
        let style = NoticeStyle.style(for: notice.kind)
        // Row body and dismiss `×` are SIBLINGS, not nested. Nesting the
        // × inside a row Button has two failure modes:
        //   1. Action-less rows (configCorruption) need `.disabled(true)`
        //      on the outer Button to avoid an inert tap region — but
        //      SwiftUI then applies a system-wide disabled tint to ALL
        //      contained views, dimming the icon, message, and ×.
        //   2. Even when the outer Button is enabled, the nested × tap
        //      gets captured by the outer hit area first, so dismiss
        //      never fires.
        // Splitting them solves both: the row body uses `.onTapGesture`
        // (only attached when an action exists), the × is its own plain
        // Button with full opacity.
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 14, alignment: .center)
                Text(notice.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let title = style.actionTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .modifier(TapAction(action: style.action.map { fn in { fn(viewModel) } }))

            Button {
                viewModel.dismissNotice(notice.kind)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
    }

    private var chevronButton: some View {
        Button {
            viewModel.toggleTrayExpanded()
        } label: {
            Image(systemName: viewModel.trayExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.trayExpanded ? "Collapse notices" : "Expand notices")
    }
}

// MARK: - Notice presentation

private struct NoticeStyle {
    let icon: String
    let tint: Color
    let actionTitle: String?
    let action: (@MainActor (NotchViewModel) -> Void)?

    static func style(for kind: SystemNoticeKind) -> NoticeStyle {
        switch kind {
        case .missingPermission:
            return NoticeStyle(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                actionTitle: "Open Settings",
                action: { vm in vm.showSettings = true }
            )
        case .missingProvider:
            return NoticeStyle(
                icon: "questionmark.circle.fill",
                tint: .yellow,
                actionTitle: "Open Settings",
                action: { vm in vm.showSettings = true }
            )
        case .configCorruption:
            return NoticeStyle(
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                actionTitle: nil,
                action: nil
            )
        }
    }
}

// MARK: - Tap helper
//
// Conditional tap gesture — only attaches when an action is provided so
// action-less notices (configCorruption) don't have a phantom hit region
// and don't pull the disabled-look tint that a `.disabled` Button would
// inflict on everything underneath it.
private struct TapAction: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Height preference

private struct TrayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
