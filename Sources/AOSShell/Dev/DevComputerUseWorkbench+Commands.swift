import CoreGraphics
import Foundation
import AOSComputerUseKit

// MARK: - Computer Use Commands

extension DevComputerUseWorkbench {
    func refreshApps() async {
        await run("computerUse.listApps") {
            let next = await service.listApps(mode: appListMode)
            let previousSelection = selectedAppIdentity
            apps = next
            selectedAppIdentity = nextSelection(in: next, previousSelection: previousSelection)
            if selectedAppIdentity != previousSelection {
                _ = await loadWindowsForSelectedApp()
            }
            lastResult = "computerUse.listApps OK: mode=\(appListMode.rawValue) \(next.count) app(s)"
        }
    }

    func refreshWindows() async {
        await run("computerUse.listWindows") {
            let count = await loadWindowsForSelectedApp()
            lastResult = "computerUse.listWindows OK: \(count) window(s)"
        }
    }

    func getAppState() async {
        await run("computerUse.getAppState") {
            let bundle = try await service.getAppState(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                captureMode: captureMode,
                maxImageDimension: try parseOptionalInt(maxImageDimension)
            )
            stateId = bundle.stateId
            axTree = bundle.treeMarkdown
            screenshot = bundle.screenshot
            let shot = bundle.screenshot.map {
                "screenshot=\($0.width)x\($0.height) \($0.format.rawValue) bytes=\($0.imageData.count)"
            } ?? "screenshot=-"
            stateSummary = [
                "stateId=\(bundle.stateId?.raw ?? "-")",
                "appName=\(bundle.appName ?? "-") bundleId=\(bundle.bundleId ?? "-")",
                "elementCount=\(bundle.elementCount.map(String.init) ?? "-")",
                shot,
            ].joined(separator: "\n")
            lastResult = "computerUse.getAppState OK"
        }
    }

    func clickElement() async {
        await run("computerUse.clickByElement") {
            let result = try await service.clickByElement(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                stateId: try requireStateId(),
                elementIndex: try parseInt(elementIndex, label: "elementIndex"),
                action: axAction.isEmpty ? "AXPress" : axAction
            )
            lastResult = "computerUse.clickByElement OK: success=\(result.success) method=\(result.method)"
        }
    }

    func clickAt() async {
        await run("computerUse.clickByCoords") {
            let result = try await service.clickByCoords(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                x: try parseDouble(x, label: "x"),
                y: try parseDouble(y, label: "y"),
                count: clickCount,
                modifiers: parseList(modifiers)
            )
            lastResult = "computerUse.clickByCoords OK: success=\(result.success) method=\(result.method)"
        }
    }

    func scroll() async {
        await run("computerUse.scroll") {
            let success = try await service.scroll(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                x: try parseDouble(scrollX, label: "scroll x"),
                y: try parseDouble(scrollY, label: "scroll y"),
                dx: Int32(try parseInt(scrollDX, label: "dx")),
                dy: Int32(try parseInt(scrollDY, label: "dy"))
            )
            lastResult = "computerUse.scroll OK: success=\(success)"
        }
    }

    func drag() async {
        await run("computerUse.drag") {
            let success = try await service.drag(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                from: CGPoint(
                    x: try parseDouble(dragFromX, label: "drag from x"),
                    y: try parseDouble(dragFromY, label: "drag from y")
                ),
                to: CGPoint(
                    x: try parseDouble(dragToX, label: "drag to x"),
                    y: try parseDouble(dragToY, label: "drag to y")
                )
            )
            lastResult = "computerUse.drag OK: success=\(success)"
        }
    }

    func typeText() async {
        await run("computerUse.typeText") {
            let success = try await service.typeText(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                text: textToType
            )
            lastResult = "computerUse.typeText OK: success=\(success)"
        }
    }

    func pressKey() async {
        await run("computerUse.pressKey") {
            let success = try await service.pressKey(
                pid: try requirePid(),
                windowId: try requireWindowId(),
                key: key,
                modifiers: parseList(keyModifiers)
            )
            lastResult = "computerUse.pressKey OK: success=\(success)"
        }
    }

    func refreshDoctor() async {
        await doctorService.refresh()
    }

    private func nextSelection(in apps: [AppInfo], previousSelection: String?) -> String? {
        if let previousSelection, apps.contains(where: { $0.identity == previousSelection }) {
            return previousSelection
        }
        return apps.first(where: \.active)?.identity
            ?? apps.first(where: \.running)?.identity
            ?? apps.first?.identity
    }

    private func loadWindowsForSelectedApp() async -> Int {
        guard let pid = selectedPid else {
            clearWindowSelection()
            return 0
        }
        let next = await service.listWindows(pid: pid).map {
            DevComputerUseWindowRow(info: $0.0, onCurrentSpace: $0.onCurrentSpace)
        }
        windows = next
        selectedWindowId = next.first(where: { $0.onCurrentSpace })?.id ?? next.first?.id
        return next.count
    }

    private func run(_ name: String, operation: () async throws -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        lastResult = "\(name) running..."
        do {
            try await operation()
        } catch {
            lastResult = nil
            lastError = "\(name) failed: \(error)"
        }
        isRunning = false
    }

    private func requirePid() throws -> pid_t {
        guard let selectedPid else {
            throw DevComputerUseInputError.missingTarget("running pid; selected app is not running")
        }
        return selectedPid
    }

    private func requireWindowId() throws -> CGWindowID {
        guard let selectedWindowId else { throw DevComputerUseInputError.missingTarget("windowId") }
        return selectedWindowId
    }

    private func requireStateId() throws -> StateID {
        guard let stateId else { throw DevComputerUseInputError.missingTarget("stateId") }
        return stateId
    }

    private func parseOptionalInt(_ value: String) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return try parseInt(trimmed, label: "maxImageDimension")
    }

    private func parseInt(_ value: String, label: String) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            throw DevComputerUseInputError.invalid(label: label, value: value)
        }
        return parsed
    }

    private func parseDouble(_ value: String, label: String) throws -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            throw DevComputerUseInputError.invalid(label: label, value: value)
        }
        return parsed
    }

    private func parseList(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map(String.init)
    }
}
