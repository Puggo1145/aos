import AOSComputerUseKit

// MARK: - Dev Summaries

extension DevComputerUseWorkbench {
    var appListSummary: String {
        guard !apps.isEmpty else { return "apps=0" }
        let runningCount = apps.filter(\.running).count
        let rows = apps.map { app in
            let pid = app.pid.map(String.init) ?? "-"
            let bundleId = app.bundleId ?? "-"
            let path = app.path ?? "-"
            let state = app.running ? "running" : "notRunning"
            let active = app.active ? " active=true" : ""
            return "- \(app.name) state=\(state)\(active) pid=\(pid) bundleId=\(bundleId) path=\"\(path)\""
        }
        return (["apps=\(apps.count) running=\(runningCount)"] + rows).joined(separator: "\n")
    }

    var enumerationSummary: String {
        let runningCount = apps.filter(\.running).count
        let appLine = "apps=\(apps.count) running=\(runningCount) selectedPid=\(selectedPid.map(String.init) ?? "-")"
        let selectedLine: String
        if let app = selectedApp {
            selectedLine = "selectedApp name=\"\(app.name)\" bundleId=\(app.bundleId ?? "-") path=\(app.path ?? "-") running=\(app.running)"
        } else {
            selectedLine = "selectedApp=-"
        }
        let windowLine = "windows=\(windows.count) selectedWindowId=\(selectedWindowId.map(String.init) ?? "-")"
        let rows = windows.map { row in
            let title = row.title.isEmpty ? "(untitled)" : row.title
            return "- id=\(row.id) z=\(row.zIndex) layer=\(row.layer) onScreen=\(row.isOnScreen) onCurrentSpace=\(row.onCurrentSpace) title=\"\(title)\""
        }
        return ([appLine, selectedLine, windowLine] + rows).joined(separator: "\n")
    }
}
