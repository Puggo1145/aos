import Testing
import Foundation
@testable import AOSShell
@testable import AOSRPCSchema

// MARK: - AgentServiceTests
//
// Drive AgentService directly via its `internal` notification handlers (no
// real RPCClient required). Asserts the state transitions described in
// docs/designs/notch-ui.md "AgentStatus → 颜文字映射" + plan §E:
//
//   thinking → done → (~1s) → idle
//   error → (~2s) → idle
//   tokens for the current turn accumulate into assistantText, stale turns drop

@MainActor
@Suite("AgentService state machine")
struct AgentServiceTests {

    /// Build a real RPCClient over a closed pipe pair so init() succeeds —
    /// no RPC traffic actually flows in these tests; we exercise handlers
    /// and the test seam directly.
    private func makeService() -> AgentService {
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        return AgentService(rpc: rpc)
    }

    @Test("tokens for unknown turn id are dropped")
    func tokensDroppedForStaleTurn() {
        let s = makeService()
        s.handleToken(UITokenParams(turnId: "T1", delta: "hi"))
        #expect(s.assistantText.isEmpty)
    }

    @Test("status notifications drive AgentStatus values")
    func statusMapping() {
        let s = makeService()
        s._testSetCurrentTurn("T1")
        s.handleStatus(UIStatusParams(turnId: "T1", status: .thinking))
        #expect(s.status == .thinking)
        s.handleStatus(UIStatusParams(turnId: "T1", status: .toolCalling))
        #expect(s.status == .working)
        s.handleStatus(UIStatusParams(turnId: "T1", status: .waitingInput))
        #expect(s.status == .waiting)
    }

    @Test("done auto-reverts to idle within ~1.5s")
    func doneRevert() async throws {
        let s = makeService()
        s._testSetCurrentTurn("T2")
        s.handleStatus(UIStatusParams(turnId: "T2", status: .done))
        #expect(s.status == .done)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(s.status == .idle)
        #expect(s.currentTurn == nil)
    }

    @Test("error auto-reverts to idle within ~2.5s")
    func errorRevert() async throws {
        let s = makeService()
        s._testSetCurrentTurn("T3")
        s.handleError(UIErrorParams(turnId: "T3", code: -32003, message: "no auth"))
        #expect(s.status == .error)
        #expect(s.lastErrorMessage == "no auth")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(s.status == .idle)
    }

    @Test("tokens for current turn append to assistantText")
    func tokensAppend() {
        let s = makeService()
        s._testSetCurrentTurn("T4")
        s.handleToken(UITokenParams(turnId: "T4", delta: "Hel"))
        s.handleToken(UITokenParams(turnId: "T4", delta: "lo"))
        #expect(s.assistantText == "Hello")
        // tokens for a stale turn drop on the floor
        s.handleToken(UITokenParams(turnId: "Tstale", delta: "X"))
        #expect(s.assistantText == "Hello")
    }
}
