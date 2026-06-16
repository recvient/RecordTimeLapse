import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let label: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// A ready-to-use capture target: the content filter + configuration plus the resolved
/// capture pixel dimensions (already resolution-capped). Built once per recording and reused
/// across every timer tick; only re-acquired on display topology change.
struct CaptureTarget {
    let displayID: CGDirectDisplayID
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let pixelWidth: Int
    let pixelHeight: Int
}

enum DisplayProvider {

    /// All displays, for the settings picker. `targetDisplayID == 0` means "main display".
    static func availableDisplays() async -> [DisplayInfo] {
        guard let content = try? await SCShareableContent.current else { return [] }
        return content.displays.map { d in
            let mode = CGDisplayCopyDisplayMode(d.displayID)
            let pw = mode?.pixelWidth ?? Int(d.width)
            let ph = mode?.pixelHeight ?? Int(d.height)
            let name = NSScreen.screens.first { $0.displayID == d.displayID }?.localizedName ?? "Display"
            return DisplayInfo(id: d.displayID, label: "\(name) — \(pw)×\(ph)", pixelWidth: pw, pixelHeight: ph)
        }
    }

    /// Real pixels-per-point for a display, derived from its current mode (fallback when
    /// SCContentFilter.pointPixelScale is unavailable). Avoids a hardcoded 2.0 that breaks
    /// non-Retina / mixed-scale external monitors.
    private static func fallbackScale(_ id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 2.0 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    /// Build the capture target for the chosen display (0 ⇒ main), applying the resolution cap.
    /// `interval` becomes the stream's `minimumFrameInterval` (the time-lapse cadence).
    /// `fixedCanvas` pins the output dimensions to an existing encoder canvas when rebuilding
    /// mid-recording — SCK then GPU-fits the (possibly different) display into the same buffer
    /// size, so the zero-copy append path stays valid across display changes.
    static func makeTarget(targetDisplayID: CGDirectDisplayID,
                           resolutionCap: ResolutionCap,
                           showsCursor: Bool,
                           interval: Double,
                           fixedCanvas: (width: Int, height: Int)? = nil) async throws -> CaptureTarget {
        let content = try await SCShareableContent.current
        guard !content.displays.isEmpty else { throw CaptureError.noDisplay }

        let main = CGMainDisplayID()
        let display = content.displays.first { targetDisplayID != 0 && $0.displayID == targetDisplayID }
            ?? content.displays.first { $0.displayID == main }
            ?? content.displays[0]

        let filter = SCContentFilter(display: display, excludingWindows: [])

        var pxW: Int
        var pxH: Int
        if let canvas = fixedCanvas {
            (pxW, pxH) = (canvas.width, canvas.height)
        } else {
            // Native pixel size of this display. pointPixelScale is ScreenCaptureKit's
            // authoritative backing scale; fall back to the display mode's pixel/point ratio.
            let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : fallbackScale(display.displayID)
            pxW = Int((CGFloat(display.width) * scale).rounded())
            pxH = Int((CGFloat(display.height) * scale).rounded())

            // Apply the long-edge cap (GPU downsamples at capture time → energy + size win).
            if resolutionCap != .native {
                let cap = resolutionCap.rawValue
                let longEdge = max(pxW, pxH)
                if longEdge > cap {
                    let f = Double(cap) / Double(longEdge)
                    pxW = Int((Double(pxW) * f).rounded())
                    pxH = Int((Double(pxH) * f).rounded())
                }
            }
            // Even dimensions for the encoder downstream.
            pxW -= pxW % 2
            pxH -= pxH % 2
        }

        let config = SCStreamConfiguration()
        // Output buffers are ALWAYS exactly this size (SCStreamOutputType.screen contract),
        // so the encoder canvas stays valid for the whole recording.
        config.width = pxW
        config.height = pxH
        config.showsCursor = showsCursor
        // Cadence lives in the stream itself: WindowServer delivers at most one frame per
        // interval, and none at all while the screen is static (idle suppression).
        config.minimumFrameInterval = CMTime(seconds: max(0.1, interval), preferredTimescale: 600)
        // 420v: SCK converts RGB→YUV in hardware during capture; the HEVC/H.264 encoder
        // consumes it natively (no per-frame conversion) at 1.5 B/px instead of 4 B/px.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2   // required for 420v/420f
        config.colorSpaceName = CGColorSpace.sRGB
        // Small surface pool (valid range 3–8): four canvas-sized YUV buffers gives one
        // buffer of headroom over the minimum for brief encoder stalls; when exhausted,
        // SCK simply skips frames (harmless for a time-lapse).
        config.queueDepth = 4
        // preservesAspectRatio defaults to true → aspect-fit into the pinned canvas.

        Log.capture.info("Capture target display=\(display.displayID) canvas=\(pxW)x\(pxH) interval=\(interval)s cursor=\(showsCursor)")
        return CaptureTarget(displayID: display.displayID, filter: filter, config: config,
                             pixelWidth: pxW, pixelHeight: pxH)
    }


    enum CaptureError: Error { case noDisplay }
}

extension NSScreen {
    /// The CGDirectDisplayID backing this NSScreen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
