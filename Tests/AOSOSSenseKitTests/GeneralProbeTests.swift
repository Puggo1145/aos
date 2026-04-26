import Testing
import Foundation
@testable import AOSOSSenseKit

@Suite("GeneralProbe — pure helpers")
struct GeneralProbeTests {

    @Test("Truncation passes through under-2KB strings unchanged")
    func truncateNoop() {
        let s = String(repeating: "a", count: 100)
        #expect(GeneralProbe.truncate(s) == s)
    }

    @Test("Truncation appends suffix with dropped character count")
    func truncateAppendsSuffix() {
        let limit = GeneralProbe.textTruncationLimit
        let s = String(repeating: "x", count: limit + 137)
        let result = GeneralProbe.truncate(s)
        #expect(result.hasSuffix("[truncated, 137 more chars]"))
        // The kept body is the configured limit length.
        #expect(result.count == limit + "[truncated, 137 more chars]".count)
    }

    @Test("selectedText envelope has stable per-pid citationKey")
    func selectedTextStableKey() {
        let env1 = GeneralProbe.makeSelectedTextEnvelope(text: "first", pid: 42)
        let env2 = GeneralProbe.makeSelectedTextEnvelope(text: "second", pid: 42)
        #expect(env1.citationKey == env2.citationKey)
        #expect(env1.kind == "general.selectedText")
        #expect(env1.citationKey == "general.selectedText:42")
    }

    @Test("currentInput envelope kind + citationKey are distinct from selectedText")
    func currentInputDistinct() {
        let txt = GeneralProbe.makeSelectedTextEnvelope(text: "a", pid: 1)
        let inp = GeneralProbe.makeCurrentInputEnvelope(value: "a", pid: 1)
        #expect(txt.kind != inp.kind)
        #expect(txt.citationKey != inp.citationKey)
    }

    @Test("selectedItems display summary is single label for one item, count otherwise")
    func selectedItemsSummary() {
        let single = GeneralProbe.makeSelectedItemsEnvelope(
            items: [SelectedItem(role: "AXRow", label: "Report.pdf", identifier: nil)],
            pid: 7
        )
        #expect(single.displaySummary == "Report.pdf")

        let multi = GeneralProbe.makeSelectedItemsEnvelope(
            items: [
                SelectedItem(role: "AXRow", label: "a", identifier: nil),
                SelectedItem(role: "AXRow", label: "b", identifier: nil),
                SelectedItem(role: "AXRow", label: "c", identifier: nil),
            ],
            pid: 7
        )
        #expect(multi.displaySummary == "3 items")
    }

    @Test("selectedText payload carries the truncated content")
    func selectedTextPayloadShape() {
        let env = GeneralProbe.makeSelectedTextEnvelope(text: "hello world", pid: 1)
        guard case let .object(obj) = env.payload,
              case let .string(content)? = obj["content"] else {
            Issue.record("expected .object with .string content")
            return
        }
        #expect(content == "hello world")
    }
}
