import Testing
import AOSComputerUseKit
import AOSOSSenseKit
@testable import AOSShell

@MainActor
@Suite("DevComputerUseWorkbench")
struct DevComputerUseWorkbenchTests {
    @Test("changing selected app clears window and captured state")
    func changingSelectedAppClearsDependentState() {
        let service = ComputerUseService()
        let workbench = DevComputerUseWorkbench(
            service: service,
            doctorService: ComputerUseDoctorService(
                service: service,
                permissions: PermissionsService()
            )
        )
        let first = AppInfo(
            pid: 1001,
            bundleId: "test.first",
            name: "First",
            path: "/Applications/First.app",
            running: true,
            active: false
        )
        let second = AppInfo(
            pid: 1002,
            bundleId: "test.second",
            name: "Second",
            path: "/Applications/Second.app",
            running: true,
            active: false
        )

        workbench.apps = [first, second]
        workbench.selectedAppIdentity = first.identity
        workbench.windows = [
            DevComputerUseWindowRow(
                info: WindowInfo(
                    id: 42,
                    pid: 1001,
                    owner: "First",
                    title: "Main",
                    bounds: WindowBounds(x: 0, y: 0, width: 100, height: 100),
                    zIndex: 0,
                    isOnScreen: true,
                    layer: 0
                ),
                onCurrentSpace: true
            )
        ]
        workbench.selectedWindowId = 42
        workbench.stateId = StateID("stale-state")
        workbench.axTree = "stale tree"
        workbench.stateSummary = "stale summary"

        workbench.selectedAppIdentity = second.identity

        #expect(workbench.windows.isEmpty)
        #expect(workbench.selectedWindowId == nil)
        #expect(workbench.stateId == nil)
        #expect(workbench.axTree == nil)
        #expect(workbench.stateSummary == nil)
    }
}
