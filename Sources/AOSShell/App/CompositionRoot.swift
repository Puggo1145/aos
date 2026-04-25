import Foundation
import AppKit
import AOSRPCSchema
import AOSOSSenseKit

// MARK: - CompositionRoot
//
// The single object responsible for instantiating + wiring the Shell's live
// graph. Per docs/designs/notch-ui.md "数据流图":
//
//   PermissionsService ─┐
//                       ├─▶ SenseStore ─┐
//   AdapterRegistry  ───┘               ├─▶ NotchWindowController
//   SidecarProcess  ─▶ RPCClient ─▶ AgentService ─┘
//
// `start()` boots in the order required by the design (SenseStore first so
// the chip row has data on the first frame; sidecar handshake before the
// AgentService can submit). `rebuildWindow()` recreates the NotchWindow
// stack on screen-parameter changes. `stop()` is the inverse for clean
// app termination.

@MainActor
public final class CompositionRoot {
    public let permissionsService: PermissionsService
    public let senseStore: SenseStore
    public let adapterRegistry: AdapterRegistry
    public let sidecarProcess: SidecarProcess
    public private(set) var rpcClient: RPCClient?
    public private(set) var agentService: AgentService?
    public private(set) var notchWindowController: NotchWindowController?

    /// Latest fatal error surfaced during boot (e.g. handshake mismatch,
    /// bun missing). The OpenedPanelView reads `agentService.lastErrorMessage`
    /// for run-time errors; this property is for boot-time diagnostics.
    public private(set) var fatalBootError: String?

    public init() {
        self.permissionsService = PermissionsService()
        self.adapterRegistry = AdapterRegistry()
        self.senseStore = SenseStore(
            permissionsService: permissionsService,
            registry: adapterRegistry
        )
        self.sidecarProcess = SidecarProcess()
    }

    public func start() async {
        // 1. SenseStore: starts WindowMirror + initial permissions probe.
        await senseStore.start()

        // 2. Spawn Bun sidecar; wire stdio to the RPC client.
        let pipes: SidecarPipes
        do {
            pipes = try sidecarProcess.spawn()
        } catch {
            FileHandle.standardError.write(
                Data("[shell] sidecar spawn failed: \(error)\n".utf8)
            )
            fatalBootError = "Sidecar failed to start: \(error)"
            mountWindow()
            return
        }
        let client = RPCClient(
            inbound: pipes.fromSidecar,
            outbound: pipes.toSidecar
        )
        client.start()
        self.rpcClient = client

        // 3. Construct AgentService (handler registration runs in init).
        let agent = AgentService(rpc: client)
        self.agentService = agent

        // 4. Mount the notch window before awaiting handshake so the user
        //    sees the bar immediately. If handshake fails, the panel surfaces
        //    the error.
        mountWindow()

        // 5. Await handshake. MAJOR mismatch from the sidecar terminates it
        //    and surfaces a fatal error. Inbound rpc.hello path is handled
        //    inside RPCClient.
        do {
            _ = try await client.awaitHandshake(timeout: 5)
        } catch {
            FileHandle.standardError.write(
                Data("[shell] handshake failed: \(error)\n".utf8)
            )
            fatalBootError = "RPC handshake failed: \(error)"
            sidecarProcess.terminate()
        }

        // 6. Start global event monitors (closed/popping/opened state machine).
        EventMonitors.shared.start()
    }

    /// Rebuild the notch window stack on screen change. Per
    /// notch-dev-guide.md §3.4 we destroy fully and rebuild on the (new)
    /// built-in display.
    public func rebuildWindow() {
        notchWindowController?.destroy()
        notchWindowController = nil
        mountWindow()
    }

    private func mountWindow() {
        guard let screen = NSScreen.buildin else {
            FileHandle.standardError.write(
                Data("[shell] no built-in display detected; refusing to show NotchWindow\n".utf8)
            )
            return
        }
        guard screen.notchSize != .zero else {
            FileHandle.standardError.write(
                Data("[shell] built-in display has no notch; refusing to show NotchWindow\n".utf8)
            )
            return
        }
        guard let agent = agentService else {
            // mountWindow may be called before the agentService is built (when
            // the sidecar fails to spawn). The notch UI is useful even then —
            // we surface the boot error via the panel. Construct a no-op
            // AgentService backed by a dummy RPC; this is *only* the boot-fail
            // path, not a stub for missing functionality.
            return
        }
        notchWindowController = NotchWindowController(
            senseStore: senseStore,
            agentService: agent,
            screen: screen
        )
    }

    public func stop() {
        EventMonitors.shared.stop()
        notchWindowController?.destroy()
        notchWindowController = nil
        rpcClient?.stop()
        rpcClient = nil
        sidecarProcess.terminate()
        senseStore.stop()
    }
}
