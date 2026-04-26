import SwiftUI
import AppKit
import AOSOSSenseKit

// MARK: - ContextChipsView
//
// Live chip row for the composer. Per the post-redesign contract:
//
//   chips = [appChip + viewfinderToggle] ++ behaviors
//
// The app chip is the basic identity and is always projected. Immediately
// to its right sits the **per-app screenshot toggle** — a viewfinder
// button that flips a `VisualCapturePolicyStore` entry for the current
// bundleId. While that toggle is on, every submit while the app is
// frontmost attaches a fresh window snapshot at submit time. State is
// process-only memory (per product decision).
//
// The clipboard chip does NOT live here. Pasted content is rendered
// inline inside the composer's input row (see `ComposerCard.inputRow`)
// because (a) the paste is a per-turn input, not ambient context, and
// (b) co-locating chip + delete affordance with the input avoids the
// dual-state confusion of "remove the chip from the top row, but the
// pasted text remains in the field below".
//
// Behavior chips remain individually selectable; deselected keys flow up
// to `ComposerCard` and are filtered out at projection time.

struct ContextChipsView: View {
    let senseStore: SenseStore
    let policyStore: VisualCapturePolicyStore
    @Binding var deselectedBehaviorKeys: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let app = senseStore.context.app {
                    appChipWithToggle(app: app)
                }
                ForEach(senseStore.context.behaviors, id: \.id) { envelope in
                    behaviorChip(envelope: envelope)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .onChange(of: senseStore.context.app?.bundleId) { _, _ in
            // App switch invalidates per-app behavior chip identities;
            // reset behavior selections so the user starts each app fresh.
            // The capture-toggle state is keyed by bundleId in the policy
            // store, so it naturally reflects the new app on its own.
            deselectedBehaviorKeys.removeAll()
        }
    }

    // MARK: - App chip + capture toggle

    /// App identity chip with the per-app screenshot toggle attached as
    /// one visual unit on its trailing edge. Replaces the old standalone
    /// "Window snapshot" chip.
    @ViewBuilder
    private func appChipWithToggle(app: AppIdentity) -> some View {
        HStack(spacing: 6) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            captureToggleButton(bundleId: app.bundleId)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private func captureToggleButton(bundleId: String) -> some View {
        let on = policyStore.isAlwaysCapture(bundleId: bundleId)
        let available = senseStore.visualSnapshotAvailable
        Button {
            // Toggle is a no-op when screen-recording isn't granted —
            // there'd be nothing to capture. Keep the button visible but
            // dimmed so the user discovers it; tapping does nothing
            // until permission is granted.
            guard available else { return }
            _ = policyStore.toggle(bundleId: bundleId)
        } label: {
            Image(systemName: on ? "eye.fill" : "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 0.95 : (available ? 0.55 : 0.25)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on
            ? "Always attach a window snapshot when sending from \(bundleId)"
            : (available
                ? "Attach a window snapshot to every send from this app"
                : "Screen recording permission required"))
        .accessibilityLabel(Text("Always capture screenshot for this app"))
        .accessibilityValue(Text(on ? "on" : "off"))
    }

    // MARK: - Behavior chip

    @ViewBuilder
    private func behaviorChip(envelope: BehaviorEnvelope) -> some View {
        let key = envelope.citationKey
        let selected = !deselectedBehaviorKeys.contains(key)
        Button {
            if selected {
                deselectedBehaviorKeys.insert(key)
            } else {
                deselectedBehaviorKeys.remove(key)
            }
        } label: {
            Text(envelope.displaySummary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 0.9 : 0.45))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.12 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(selected ? 0 : 0.18),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(envelope.displaySummary))
        .accessibilityValue(Text(selected ? "selected" : "deselected"))
    }

}
