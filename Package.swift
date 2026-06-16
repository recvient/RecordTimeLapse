// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RecordTimeLapse",
    platforms: [
        // Baseline: macOS 14 (Sonoma) for SCScreenshotManager.captureImage + @Observable.
        // macOS 26/27 paths are gated behind @available at the call sites.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RecordTimeLapse",
            path: "Sources/RecordTimeLapse",
            swiftSettings: [
                // Swift 5 language mode: AVFoundation/CoreGraphics/ScreenCaptureKit deal in
                // non-Sendable CF types (CGImage, CVPixelBuffer) that we hand across queues by
                // design. The concurrency is correct (serial encode queue + main-thread model
                // mutation); v5 mode keeps the build clean without a sea of Sendable shims.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Embed Info.plist into the executable so the raw binary (and the bundled .app)
                // carry the bundle id / usage strings. Verified with swift build run from the
                // package root, where "Info.plist" resolves. See Scripts/build_app.sh.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "RecordTimeLapseTests",
            dependencies: ["RecordTimeLapse"],
            path: "Tests/RecordTimeLapseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
