import Testing
import Foundation
import AppKit
@testable import AOSOSSenseKit

@MainActor
@Suite("ClipboardWatcher — extraction + priority")
struct ClipboardWatcherTests {

    /// Allocate a private NSPasteboard so concurrent tests don't fight over
    /// `NSPasteboard.general`. Each test gets a fresh board with only the
    /// types it sets.
    private func makePasteboard(name: String = UUID().uuidString) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(name))
    }

    @Test("text-only pasteboard yields .text item")
    func textOnly() async {
        let pb = makePasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("hello clipboard", forType: .string)

        var captured: ClipboardItem?
        let watcher = ClipboardWatcher(pasteboard: pb) { item in
            captured = item
        }
        watcher.start()
        defer { watcher.stop() }

        guard case let .text(s) = captured else {
            Issue.record("expected .text, got \(String(describing: captured))")
            return
        }
        #expect(s == "hello clipboard")
    }

    @Test("text > 2KB is truncated with the GeneralProbe rule")
    func textTruncated() async {
        let pb = makePasteboard()
        let limit = ClipboardWatcher.textTruncationLimit
        let big = String(repeating: "z", count: limit + 50)
        pb.declareTypes([.string], owner: nil)
        pb.setString(big, forType: .string)

        var captured: ClipboardItem?
        let watcher = ClipboardWatcher(pasteboard: pb) { item in
            captured = item
        }
        watcher.start()
        defer { watcher.stop() }

        guard case let .text(s) = captured else {
            Issue.record("expected .text item")
            return
        }
        #expect(s.hasSuffix("[truncated, 50 more chars]"))
    }

    @Test("file URLs win over plain text per design priority")
    func filePathsBeatText() async {
        let pb = makePasteboard()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt")
        try? "hello".write(to: file, atomically: true, encoding: .utf8)

        // Write both types — watcher must prefer file URLs.
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        pb.setString("ignored text", forType: .string)

        var captured: ClipboardItem?
        let watcher = ClipboardWatcher(pasteboard: pb) { item in
            captured = item
        }
        watcher.start()
        defer { watcher.stop() }

        guard case let .filePaths(urls) = captured else {
            Issue.record("expected .filePaths, got \(String(describing: captured))")
            return
        }
        #expect(urls.first?.lastPathComponent == "note.txt")
    }

    @Test("Empty pasteboard yields nil item")
    func emptyYieldsNil() async {
        let pb = makePasteboard()
        pb.clearContents()

        var fired = false
        var captured: ClipboardItem?
        let watcher = ClipboardWatcher(pasteboard: pb) { item in
            fired = true
            captured = item
        }
        watcher.start()
        defer { watcher.stop() }

        #expect(fired)
        #expect(captured == nil)
    }

    @Test("changeCount idempotency: tick without change does not re-emit")
    func tickIdempotent() async {
        let pb = makePasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("once", forType: .string)

        var emissions = 0
        let watcher = ClipboardWatcher(pasteboard: pb) { _ in
            emissions += 1
        }
        watcher.start()
        defer { watcher.stop() }

        // start() emits once for the initial state.
        let initialCount = emissions
        watcher._tickForTesting()
        watcher._tickForTesting()
        #expect(emissions == initialCount)
    }

    @Test("Clipboard mutation between ticks emits a fresh item")
    func tickReemitsOnMutation() async {
        let pb = makePasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("first", forType: .string)

        var captured: [ClipboardItem?] = []
        let watcher = ClipboardWatcher(pasteboard: pb) { item in
            captured.append(item)
        }
        watcher.start()
        defer { watcher.stop() }

        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString("second", forType: .string)
        watcher._tickForTesting()

        let lastText: String? = {
            if case let .text(s)? = captured.last { return s }
            return nil
        }()
        #expect(lastText == "second")
    }
}
