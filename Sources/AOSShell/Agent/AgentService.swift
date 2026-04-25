import Foundation
import AOSRPCSchema

// MARK: - AgentStatus
//
// View-facing status enum. `listening` is NOT pushed by the sidecar — it's a
// view-local override that the panel applies when the input field is focused
// (per notch-ui.md "AgentStatus → 颜文字映射"). Service-side this enum still
// includes the case so the view layer can use a single type end-to-end.

public enum AgentStatus: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case working
    case done
    case waiting
    case error
}

// MARK: - AgentService
//
// Per docs/designs/notch-ui.md "数据流图" + plan §E. Single Observable
// service that:
//   - owns the current turn id
//   - fan-ins `ui.token` / `ui.status` / `ui.error` notifications into
//     status + assistantText state
//   - exposes `submit(prompt:citedContext:)` and `cancel()` to the view
//
// Status reverts:
//   - `done` auto-reverts to `idle` after 1s
//   - `error` auto-reverts to `idle` after 2s
// Both reverts are cancellable so a new turn or new error preempts cleanly.

@MainActor
@Observable
public final class AgentService {
    public private(set) var currentTurn: String?
    public private(set) var status: AgentStatus = .idle
    public private(set) var assistantText: String = ""
    public private(set) var lastErrorMessage: String?

    private let rpc: RPCClient
    private var doneRevertTask: Task<Void, Never>?
    private var errorRevertTask: Task<Void, Never>?

    public init(rpc: RPCClient) {
        self.rpc = rpc
        registerHandlers()
    }

    private func registerHandlers() {
        rpc.registerNotificationHandler(method: RPCMethod.uiToken) { [weak self] (params: UITokenParams) in
            await self?.handleToken(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiStatus) { [weak self] (params: UIStatusParams) in
            await self?.handleStatus(params)
        }
        rpc.registerNotificationHandler(method: RPCMethod.uiError) { [weak self] (params: UIErrorParams) in
            await self?.handleError(params)
        }
    }

    // MARK: - Public API

    public func submit(prompt: String, citedContext: CitedContext) async {
        let turnId = UUID().uuidString
        currentTurn = turnId
        assistantText = ""
        lastErrorMessage = nil
        status = .thinking
        cancelReverts()
        do {
            _ = try await rpc.request(
                method: RPCMethod.agentSubmit,
                params: AgentSubmitParams(
                    turnId: turnId,
                    prompt: prompt,
                    citedContext: citedContext
                ),
                as: AgentSubmitResult.self
            )
            // ack only — actual content streams via ui.* notifications.
        } catch {
            await raiseError(message: String(describing: error))
        }
    }

    public func cancel() async {
        guard let turnId = currentTurn else { return }
        _ = try? await rpc.request(
            method: RPCMethod.agentCancel,
            params: AgentCancelParams(turnId: turnId),
            as: AgentCancelResult.self
        )
        currentTurn = nil
        status = .idle
        cancelReverts()
    }

    // MARK: - Notification handlers

    /// Visible to tests via `@testable import` so synthetic notifications can
    /// drive the state machine without a real RPCClient.
    internal func handleToken(_ p: UITokenParams) {
        guard p.turnId == currentTurn else { return }
        assistantText.append(p.delta)
    }

    internal func handleStatus(_ p: UIStatusParams) {
        guard p.turnId == currentTurn else { return }
        switch p.status {
        case .thinking:
            status = .thinking
            cancelReverts()
        case .toolCalling:
            status = .working
            cancelReverts()
        case .waitingInput:
            status = .waiting
            cancelReverts()
        case .done:
            status = .done
            scheduleDoneRevert()
        }
    }

    internal func handleError(_ p: UIErrorParams) {
        guard p.turnId == currentTurn else { return }
        status = .error
        lastErrorMessage = p.message
        scheduleErrorRevert()
    }

    private func raiseError(message: String) async {
        status = .error
        lastErrorMessage = message
        scheduleErrorRevert()
    }

    private func scheduleDoneRevert() {
        doneRevertTask?.cancel()
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.status = .idle
                self.currentTurn = nil
            }
        }
    }

    private func scheduleErrorRevert() {
        errorRevertTask?.cancel()
        errorRevertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.status = .idle
                self.currentTurn = nil
            }
        }
    }

    // MARK: - Test seams
    //
    // `currentTurn` is `private(set)` for production safety, but tests need
    // to drive the state machine without running a full submit + RPC ack
    // dance. This `internal` setter is reachable via `@testable import`.

    internal func _testSetCurrentTurn(_ id: String?) {
        currentTurn = id
    }

    private func cancelReverts() {
        doneRevertTask?.cancel()
        errorRevertTask?.cancel()
        doneRevertTask = nil
        errorRevertTask = nil
    }
}
