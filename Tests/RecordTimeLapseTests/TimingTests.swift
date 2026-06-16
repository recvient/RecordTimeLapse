import XCTest
@testable import RecordTimeLapse

final class TimingTests: XCTestCase {

    /// The core decoupling guarantee: video length depends only on frame count and output FPS,
    /// NOT on the real capture interval. This is what turns 12 hours of screen time into minutes.
    @MainActor
    func testVideoLengthIsFrameCountOverFPS() {
        let model = RecorderModel()

        // 12 h captured every 2 s = 21,600 frames.
        model.frameCount = 21_600
        // At 30 fps → 720 s = 12 minutes, regardless of the 2 s capture spacing.
        XCTAssertEqual(model.projectedVideoLength(outputFPS: 30), 720, accuracy: 0.001)

        // Same frames at 60 fps → half the length.
        XCTAssertEqual(model.projectedVideoLength(outputFPS: 60), 360, accuracy: 0.001)
    }

    func testDurationFormatting() {
        XCTAssertEqual(MenuBarContent.formatDuration(0), "0:00")
        XCTAssertEqual(MenuBarContent.formatDuration(65), "1:05")
        XCTAssertEqual(MenuBarContent.formatDuration(3_661), "1:01:01")
    }

    /// Resolution caps must stay even-friendly long edges so the encoder gets valid dimensions.
    func testResolutionCaps() {
        XCTAssertEqual(ResolutionCap.wqhd.rawValue, 2560)
        XCTAssertEqual(ResolutionCap.native.rawValue, 0)
        for cap in ResolutionCap.allCases where cap != .native {
            XCTAssertEqual(cap.rawValue % 2, 0)
        }
    }
}
