// swift-tools-version: 5.10
import PackageDescription

// AOS SwiftPM workspace.
//
// Declares three targets per docs/plans/agents-md-notch-ui-crispy-horizon.md §A:
//   - executable `AOSShell` (Notch UI + RPC client + AgentService composition root)
//   - library `AOSRPCSchema`     (Stage 1 of docs/plans/rpc-protocol.md)
//   - library `AOSOSSenseKit`    (OS Sense Stage 0 minimal slice)
//
// Stage 1+ packages (AOSComputerUseKit, AOSAXSupport) are added by later
// stages and intentionally absent from this round.
let package = Package(
    name: "AOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AOSShell",
            targets: ["AOSShell"]
        ),
        .library(
            name: "AOSRPCSchema",
            targets: ["AOSRPCSchema"]
        ),
        .library(
            name: "AOSOSSenseKit",
            targets: ["AOSOSSenseKit"]
        )
    ],
    targets: [
        .target(
            name: "AOSRPCSchema",
            path: "Sources/AOSRPCSchema"
        ),
        .testTarget(
            name: "AOSRPCSchemaTests",
            dependencies: ["AOSRPCSchema"],
            path: "Tests/AOSRPCSchemaTests"
        ),
        // OS Sense Stage 0 — read-side OS state mirror. No dependency on
        // `AOSRPCSchema`: per `docs/designs/os-sense.md` "依赖方向（核心契约）",
        // OS Sense is read-side, RPC is wire — strict module isolation. The
        // Shell composition layer projects from the live model to the wire
        // schema; this package never imports the wire types.
        .target(
            name: "AOSOSSenseKit",
            path: "Sources/AOSOSSenseKit"
        ),
        .testTarget(
            name: "AOSOSSenseKitTests",
            dependencies: ["AOSOSSenseKit"],
            path: "Tests/AOSOSSenseKitTests"
        ),
        // AOSShell — the macOS Notch UI executable. Depends on both library
        // targets; bundles Info.plist and AOS.entitlements as resources via
        // `.copy(...)` so they're addressable from `Bundle.main.resourceURL`
        // when the .app bundle is assembled by Scripts/build-app.sh.
        // AOSShell `swift build` emits a bare Mach-O; the .app bundle layout
        // (including Info.plist and entitlements from Sources/AOSShellResources/)
        // is assembled by Scripts/build-app.sh — see docs/plans/.../§B. Those
        // files are intentionally NOT declared as SwiftPM resources because
        // SwiftPM forbids `.copy(...)` paths outside the target directory and
        // bundling them under .resources would put them inside the executable's
        // resource bundle rather than at Contents/Info.plist where macOS expects
        // them.
        .executableTarget(
            name: "AOSShell",
            dependencies: ["AOSRPCSchema", "AOSOSSenseKit"],
            path: "Sources/AOSShell",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=minimal")
            ]
        ),
        .testTarget(
            name: "AOSShellTests",
            dependencies: ["AOSShell", "AOSRPCSchema", "AOSOSSenseKit"],
            path: "Tests/AOSShellTests"
        )
    ]
)
