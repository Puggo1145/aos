import Testing
import Foundation
@testable import AOSShell
@testable import AOSRPCSchema

// MARK: - RPCClientCodecTests
//
// Exercise the RPCClient over an in-process pipe pair. We feed canonical
// NDJSON frames into the inbound pipe and assert the client correctly:
//   - completes a typed `request(...)` with a matching `RPCResponse`
//   - throws `RPCClientError.server` for an `RPCErrorResponse`
//   - dispatches notifications to registered handlers
//   - errors out on `payloadTooLarge` for >2MB single lines
//   - rejects MAJOR mismatch in awaitHandshake() via the inbound rpc.hello path

@Suite("RPCClient NDJSON codec", .serialized)
struct RPCClientCodecTests {

    /// Make an RPCClient backed by two pipes. We write to `serverToClient.write`
    /// to deliver inbound frames, and read from `clientToServer.read` to
    /// inspect what the client sent. The server-side read end is set to
    /// O_NONBLOCK so polling reads in tests don't pin the async executor.
    private func makeClient() -> (
        client: RPCClient,
        serverWrite: FileHandle,
        serverRead: FileHandle
    ) {
        let inbound = Pipe()   // server → client
        let outbound = Pipe()  // client → server
        let client = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        client.start()
        // Make the read side non-blocking.
        let fd = outbound.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return (
            client: client,
            serverWrite: inbound.fileHandleForWriting,
            serverRead: outbound.fileHandleForReading
        )
    }

    private func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    @Test("notification handler is invoked with decoded params")
    func notificationDispatch() async throws {
        let (client, serverWrite, _) = makeClient()
        defer { client.stop() }

        let received = Lock<UITokenParams?>(nil)
        client.registerNotificationHandler(method: RPCMethod.uiToken) { (params: UITokenParams) in
            received.set(params)
        }

        let notif = RPCNotification(
            method: RPCMethod.uiToken,
            params: UITokenParams(turnId: "T1", delta: "hello")
        )
        try serverWrite.write(contentsOf: encodeLine(notif))

        // Poll for the handler to fire.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if received.get() != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let got = received.get()
        #expect(got?.turnId == "T1")
        #expect(got?.delta == "hello")
    }

    @Test("notifications are delivered to handlers in wire arrival order")
    func notificationOrderingPreservedAcrossHandlerSuspensions() async throws {
        // Regression test for the streaming-token race: when each notification
        // was dispatched into its own `Task.detached`, multiple `ui.token`
        // deltas raced and the MainActor handler appended them out of order
        // (e.g. wire "Hi", "! How" landed in the reply as "! HowHi").
        //
        // The old implementation passes `notificationDispatch` (one delta in,
        // one delta out) but fails here as soon as the handler suspends a few
        // times mid-way: the detached tasks for later deltas leapfrog the
        // earlier ones during the yields. The current single-consumer
        // implementation `await`s each handler before pulling the next item,
        // so order is preserved regardless of internal suspensions.
        let (client, serverWrite, _) = makeClient()
        defer { client.stop() }

        let n = 50
        let collected = Lock<[String]>([])
        client.registerNotificationHandler(method: RPCMethod.uiToken) { (params: UITokenParams) in
            // Several explicit yields so the cooperative scheduler has real
            // chances to interleave concurrent handlers in the broken
            // implementation. Without these, even detached tasks may finish
            // before the next notification is parsed and look ordered by luck.
            for _ in 0..<5 { await Task.yield() }
            var current = collected.get()
            current.append(params.delta)
            collected.set(current)
        }

        // Fire the notifications back-to-back. Deltas are zero-padded so a
        // simple lexicographic compare matches the numeric order — easier to
        // eyeball in failure output than raw integers.
        for i in 0..<n {
            let delta = String(format: "%03d", i)
            let notif = RPCNotification(
                method: RPCMethod.uiToken,
                params: UITokenParams(turnId: "T1", delta: delta)
            )
            try serverWrite.write(contentsOf: encodeLine(notif))
        }

        // Poll until all deltas are collected (or fail the test if we time out).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if collected.get().count == n { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let got = collected.get()
        #expect(got.count == n)
        let expected = (0..<n).map { String(format: "%03d", $0) }
        #expect(got == expected)
    }

    @Test("typed request resolves on matching response id")
    func requestResolvesOnResponse() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        // Spawn the request in the background.
        let task = Task {
            try await client.request(
                method: RPCMethod.rpcPing,
                params: PingParams(),
                as: PingResult.self
            )
        }

        // Read what the client sent so we can echo the same id back.
        let outboundFrame = try await readOneLine(from: serverRead, timeout: 2)
        let probe = try JSONDecoder().decode(SentRequestProbe.self, from: outboundFrame)
        let response = RPCResponse(id: probe.id, result: PingResult())
        try serverWrite.write(contentsOf: encodeLine(response))

        _ = try await task.value
    }

    @Test("server error envelope surfaces as RPCClientError.server")
    func serverErrorMaps() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        let task = Task { () -> Result<PingResult, Error> in
            do {
                let r = try await client.request(
                    method: RPCMethod.rpcPing,
                    params: PingParams(),
                    as: PingResult.self
                )
                return .success(r)
            } catch {
                return .failure(error)
            }
        }

        let frame = try await readOneLine(from: serverRead, timeout: 2)
        let probe = try JSONDecoder().decode(SentRequestProbe.self, from: frame)
        let err = RPCErrorResponse(
            id: probe.id,
            error: RPCError(code: RPCErrorCode.permissionDenied, message: "no auth")
        )
        try serverWrite.write(contentsOf: encodeLine(err))

        let result = await task.value
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let error):
            guard case let RPCClientError.server(serverErr) = error else {
                Issue.record("expected .server error, got \(error)")
                return
            }
            #expect(serverErr.code == RPCErrorCode.permissionDenied)
        }
    }

    @Test("outbound request exceeding the 2 MiB line cap is rejected before any byte is written")
    func outboundOversizeRejected() async throws {
        let (client, _, serverRead) = makeClient()
        defer { client.stop() }

        // 3 MiB ASCII prompt — well past the 2 MiB MAX_LINE_BYTES cap that
        // both the local encoder and the sidecar transport enforce. Pure
        // ASCII so the encoded JSON length tracks the raw character count
        // (no surprise expansion that would let a smaller string also
        // overflow and confuse the assertion).
        let huge = String(repeating: "x", count: 3 * 1024 * 1024)
        let params = AgentSubmitParams(
            turnId: "T1",
            prompt: huge,
            citedContext: CitedContext()
        )

        do {
            _ = try await client.request(
                method: RPCMethod.agentSubmit,
                params: params,
                as: AgentSubmitResult.self,
                timeout: 0.2
            )
            Issue.record("expected outboundPayloadTooLarge to throw")
        } catch let RPCClientError.outboundPayloadTooLarge(method, bytes, limit) {
            #expect(method == RPCMethod.agentSubmit)
            #expect(bytes > limit)
            #expect(limit == 2 * 1024 * 1024)
        } catch {
            Issue.record("expected outboundPayloadTooLarge, got \(error)")
        }

        // Nothing should have hit the wire — the guard runs before write().
        // Poll briefly to make sure no deferred write sneaks in.
        try await Task.sleep(nanoseconds: 100_000_000)
        let fd = serverRead.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 64)
        let n = scratch.withUnsafeMutableBufferPointer { ptr in
            read(fd, ptr.baseAddress, ptr.count)
        }
        // Non-blocking fd: -1 with EAGAIN means no bytes available, which is
        // exactly what we want. A positive n would mean the guard leaked
        // a write past the size check.
        #expect(n <= 0)
    }

    @Test("majorVersion parses the leading integer")
    func majorVersionParse() {
        #expect(RPCClient.majorVersion("1.2.3") == 1)
        #expect(RPCClient.majorVersion("2.0.0") == 2)
        #expect(RPCClient.majorVersion("garbage") == 0)
    }

    @Test("rpc.hello inbound with MAJOR mismatch is rejected (no handshakeResult)")
    func handshakeMajorMismatch() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        // Send a hello with MAJOR = 99 (our local is "1.0.0").
        let req = RPCRequest(
            id: .string("hello-1"),
            method: RPCMethod.rpcHello,
            params: HelloParams(
                protocolVersion: "99.0.0",
                clientInfo: ClientInfo(name: "fake", version: "0")
            )
        )
        try serverWrite.write(contentsOf: encodeLine(req))

        // Client should reply with an error envelope. Wait for the handshake
        // to time out (we pass a tight 0.5s) and assert it does.
        do {
            _ = try await client.awaitHandshake(timeout: 0.5)
            Issue.record("expected timeout for MAJOR mismatch")
        } catch RPCClientError.timeout {
            // expected: client emitted error to peer, did not record success
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Inspect what the client wrote back: should be an error envelope
        // with code invalidRequest.
        let response = try await readOneLine(from: serverRead, timeout: 2)
        let errResp = try JSONDecoder().decode(RPCErrorResponse.self, from: response)
        #expect(errResp.error.code == RPCErrorCode.invalidRequest)
    }

    // MARK: - Helpers

    private struct SentRequestProbe: Decodable {
        let id: RPCId
        let method: String
    }

    /// Read a single newline-terminated frame from a non-blocking fd, waiting
    /// up to `timeout`s. Uses raw `read(2)` so EAGAIN can be polled cleanly.
    private func readOneLine(from handle: FileHandle, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = handle.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<nl)
            }
            let n = scratch.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                buffer.append(scratch, count: n)
                continue
            }
            if n == 0 {
                throw RPCClientError.connectionClosed
            }
            // n < 0: EAGAIN expected on non-blocking fd. Sleep + retry.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw RPCClientError.timeout(method: "test:readOneLine")
    }
}

// Tiny thread-safe box for cross-Task assertions inside tests.
final class Lock<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
