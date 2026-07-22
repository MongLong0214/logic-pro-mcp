// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogicProMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LogicProMCP", targets: ["LogicProMCPCLI"]),
        .executable(name: "trusted-verifier", targets: ["TrustedVerifier"]),
    ],
    dependencies: [
        // swift-sdk 0.11.0+ adopts the short-form
        // `withThrowingTaskGroup { group in }` syntax (Swift 6.2 inference).
        // CI requires Xcode 16.4+ (Swift 6.2) — see .github/workflows/ci.yml.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // H-5 (2026-05-08 enterprise review) — honest-deferred again in
        // v3.4.0. The deprecation warning ("Swift Testing is now included
        // in the Swift 6 toolchain. Remove your 'swift-testing' package
        // dependency to silence this warning.") suggests removal, but the
        // bundled Testing framework in Swift 6.0/6.2 still emits
        // `missing required module '_TestingInternals'` when compiled via
        // SwiftPM CLI (`swift test`) — confirmed twice in this repo (prior
        // attempt logged in PATTERN_LOG, retry on 2026-05-08 hit the same
        // error). Apple has not yet shipped the SwiftPM-side glue that
        // makes the bundled framework usable without the explicit package
        // dep. Pinned to 0.12.0 with the deprecation noise as a known
        // tradeoff until Apple closes the gap.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
        // Test-only: a Swift-syntax-aware call-site lint (MIDIReadbackCallSiteLintTests)
        // needs correct lexing to prove the dark MIDI-readback core has no
        // production caller. Pinned to the same 600.x already resolved transitively
        // via swift-testing, so this adds no new resolved version.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "LogicProMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/LogicProMCP",
            swiftSettings: [
                // #399 (CEO audit P0) — the qualification fault-injection seam is
                // a TEST affordance, never a shipped feature. Compiling it only in
                // debug guarantees a release binary contains no
                // `LOGIC_PRO_MCP_FAULT_INJECT` string and no code path that acts on
                // it, so its ordinary process environment cannot activate a fault.
                .define("QUALIFICATION_FAULT_SEAM", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "LogicProMCPCLI",
            dependencies: ["LogicProMCP"],
            path: "Sources/LogicProMCPCLI"
        ),
        .executableTarget(
            name: "TrustedVerifier",
            dependencies: ["LogicProMCP"],
            path: "Sources/TrustedVerifier"
        ),
        .testTarget(
            name: "LogicProMCPTests",
            dependencies: [
                "LogicProMCP",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "Tests/LogicProMCPTests",
            swiftSettings: [
                // #399 (CEO audit P0) — mirror the LogicProMCP target's
                // configuration-scoped define on the test target. `#if
                // QUALIFICATION_FAULT_SEAM` test code then aligns with the module
                // under test: the seam tests compile and run in the debug build
                // (where the module HAS the seam symbols) and are compiled out of a
                // `-c release` test build (where the module has NONE), so the
                // release-config test target references no excluded symbols and
                // builds clean.
                .define("QUALIFICATION_FAULT_SEAM", .when(configuration: .debug)),
            ]
        ),
    ]
)
