import Testing
import Foundation
import AppKit
import AOSOSSenseKit
import AOSRPCSchema
@testable import AOSShell

@Suite("CitedContextProjection — selection + field projection")
struct CitedContextProjectionTests {

    private func envelope(_ kind: String, _ key: String, _ summary: String) -> AOSOSSenseKit.BehaviorEnvelope {
        AOSOSSenseKit.BehaviorEnvelope(
            kind: kind,
            citationKey: key,
            displaySummary: summary,
            payload: .object(["k": .string("v")])
        )
    }

    private func ctx(
        app: AppIdentity? = nil,
        behaviors: [AOSOSSenseKit.BehaviorEnvelope] = [],
        clipboard: ClipboardItem? = nil
    ) -> SenseContext {
        SenseContext(
            app: app,
            window: app.map { WindowIdentity(title: $0.name, windowId: nil) },
            behaviors: behaviors,
            clipboard: clipboard,
            permissions: PermissionState(denied: [])
        )
    }

    @Test("Empty SenseContext projects to all-nil CitedContext")
    func emptyProjection() {
        let result = CitedContextProjection.project(from: ctx())
        #expect(result.app == nil)
        #expect(result.window == nil)
        #expect(result.behaviors == nil)
        #expect(result.visual == nil)
        #expect(result.clipboard == nil)
    }

    @Test("App + behaviors travel through unchanged with default selection")
    func defaultSelection() {
        let app = AppIdentity(bundleId: "com.x", name: "X", pid: 1, icon: nil)
        let env = envelope("general.selectedText", "g:1", "snip")
        let result = CitedContextProjection.project(
            from: ctx(app: app, behaviors: [env])
        )
        #expect(result.app?.bundleId == "com.x")
        #expect(result.behaviors?.count == 1)
        #expect(result.behaviors?.first?.kind == "general.selectedText")
    }

    @Test("Deselected citationKey is filtered out of the wire envelope list")
    func deselectFiltersOne() {
        let app = AppIdentity(bundleId: "com.x", name: "X", pid: 1, icon: nil)
        let kept = envelope("general.selectedText", "k:keep", "kept")
        let dropped = envelope("general.selectedItems", "k:drop", "dropped")
        let result = CitedContextProjection.project(
            from: ctx(app: app, behaviors: [kept, dropped]),
            selection: CitedSelection(deselectedBehaviors: ["k:drop"])
        )
        #expect(result.behaviors?.count == 1)
        #expect(result.behaviors?.first?.citationKey == "k:keep")
    }

    @Test("Deselecting all behaviors drops the slot entirely (omit, not empty)")
    func deselectAllOmitsSlot() {
        let app = AppIdentity(bundleId: "com.x", name: "X", pid: 1, icon: nil)
        let env = envelope("general.selectedText", "k:1", "x")
        let result = CitedContextProjection.project(
            from: ctx(app: app, behaviors: [env]),
            selection: CitedSelection(deselectedBehaviors: ["k:1"])
        )
        #expect(result.behaviors == nil)
    }

    @Test("Clipboard de-selection drops it from the wire payload")
    func clipboardDeselected() {
        let result = CitedContextProjection.project(
            from: ctx(clipboard: .text("secret token")),
            selection: CitedSelection(clipboardSelected: false)
        )
        #expect(result.clipboard == nil)
    }

    @Test("Clipboard text projection preserves the (already-truncated) content")
    func clipboardTextPassthrough() {
        let result = CitedContextProjection.project(
            from: ctx(clipboard: .text("hello"))
        )
        guard case let .text(s)? = result.clipboard else {
            Issue.record("expected .text clipboard")
            return
        }
        #expect(s == "hello")
    }

    @Test("Clipboard filePaths projects to absolute path strings")
    func clipboardFilePaths() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let result = CitedContextProjection.project(
            from: ctx(clipboard: .filePaths([url]))
        )
        guard case let .filePaths(paths)? = result.clipboard else {
            Issue.record("expected .filePaths")
            return
        }
        #expect(paths == ["/tmp/x.txt"])
    }

    @Test("Clipboard image projects metadata only, never pixels")
    func clipboardImageMetadataOnly() {
        let metadata = ImageMetadata(width: 800, height: 600, type: "public.png")
        let result = CitedContextProjection.project(
            from: ctx(clipboard: .image(metadata: metadata))
        )
        guard case let .image(meta)? = result.clipboard else {
            Issue.record("expected .image")
            return
        }
        #expect(meta.width == 800)
        #expect(meta.height == 600)
        #expect(meta.type == "public.png")
    }

    @Test("JSONValue conversion handles every variant")
    func jsonValueConversion() {
        let env = AOSOSSenseKit.BehaviorEnvelope(
            kind: "k",
            citationKey: "ck",
            displaySummary: "s",
            payload: .object([
                "n": .null,
                "b": .bool(true),
                "i": .int(7),
                "d": .double(1.5),
                "s": .string("x"),
                "a": .array([.int(1), .int(2)]),
                "o": .object(["nested": .bool(false)]),
            ])
        )
        let result = CitedContextProjection.project(
            from: ctx(behaviors: [env])
        )
        guard case let .object(payload)? = result.behaviors?.first?.payload else {
            Issue.record("expected object payload")
            return
        }
        #expect(payload["n"] == .null)
        #expect(payload["b"] == .bool(true))
        #expect(payload["i"] == .int(7))
        #expect(payload["d"] == .double(1.5))
        #expect(payload["s"] == .string("x"))
        guard case let .array(arr) = payload["a"] else {
            Issue.record("expected array")
            return
        }
        #expect(arr.count == 2)
    }

    @Test("Visual is passed in by the caller (captured on demand at submit)")
    func visualPassedInExplicitly() {
        let ctxRef = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let img = ctxRef.makeImage()!
        let visual = VisualMirror(
            latestFrame: img,
            frameSize: CGSize(width: 32, height: 32),
            capturedAt: Date()
        )
        // Visual is no longer pulled from SenseContext; it's a parameter so
        // the caller decides exactly when to capture.
        let result = CitedContextProjection.project(from: ctx(), visual: visual)
        let projected = result.visual
        #expect(projected != nil)
        #expect(projected?.frameSize.width == 32)
        #expect(projected?.frameSize.height == 32)
        #expect((projected?.frame.count ?? 0) > 0)
    }

    @Test("Omitted visual produces no wire visual field")
    func visualOmittedByDefault() {
        let result = CitedContextProjection.project(from: ctx())
        #expect(result.visual == nil)
    }

    @Test("base64 budget check counts encoded length, not raw bytes")
    func base64BudgetGuard() {
        // Pre-fix: `data.count <= 400KB` accepted any raw PNG up to 400KB,
        // so the encoded base64 (~533KB) silently overran the wire cap.
        // Post-fix: `data.count * 4 / 3 <= 400KB` rejects anything whose
        // encoded form would exceed 400KB. A 350KB raw blob is the canonical
        // regression case (350 * 4/3 ≈ 466KB > 400KB).
        let limit = 400 * 1024
        let underBudget = Data(count: 290 * 1024)   // 290 * 4/3 ≈ 387 KB
        let atBoundary = Data(count: 300 * 1024)    // 300 * 4/3 = 400 KB
        let overBudget = Data(count: 350 * 1024)    // 350 * 4/3 ≈ 466 KB
        #expect(CitedContextProjection.fitsBase64Budget(underBudget, limit: limit))
        #expect(CitedContextProjection.fitsBase64Budget(atBoundary, limit: limit))
        #expect(!CitedContextProjection.fitsBase64Budget(overBudget, limit: limit))
    }

    @Test("Deselected visual is dropped even when a frame was captured")
    func visualDeselectedDrops() {
        let ctxRef = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let img = ctxRef.makeImage()!
        let visual = VisualMirror(
            latestFrame: img,
            frameSize: CGSize(width: 16, height: 16),
            capturedAt: Date()
        )
        let result = CitedContextProjection.project(
            from: ctx(),
            selection: CitedSelection(visualSelected: false),
            visual: visual
        )
        #expect(result.visual == nil)
    }
}
