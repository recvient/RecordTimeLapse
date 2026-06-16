import Foundation
import CoreVideo
import CoreGraphics

/// Draws a `CGImage` into a pooled BGRA `CVPixelBuffer`, scaling and letter-boxing it into
/// the encoder's fixed canvas. The fixed canvas is what lets a recording survive a mid-run
/// display change (monitor unplugged, HiDPI scale change): incoming frames of any size are
/// fitted into the immutable writer dimensions instead of resizing the writer (impossible).
enum PixelBufferRenderer {

    // Created once: this runs on every frame for the lifetime of a 12h+ recording.
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    static func draw(_ cgImage: CGImage, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let canvasW = CVPixelBufferGetWidth(pixelBuffer)
        let canvasH = CVPixelBufferGetHeight(pixelBuffer)

        // 32BGRA == byteOrder32Little + premultipliedFirst. This matches the hardware encoder's
        // native layout (no CPU swizzle). Use CVPixelBufferGetBytesPerRow, NOT width*4 — the
        // pool may pad rows.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: base,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: Self.colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let cW = CGFloat(canvasW)
        let cH = CGFloat(canvasH)

        // Fast path: exact match → fill the whole canvas, no background clear needed.
        if Int(imgW) == canvasW && Int(imgH) == canvasH {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cW, height: cH))
            return
        }

        // Letterbox: clear to black, then aspect-fit centered.
        ctx.setFillColor(Self.black)
        ctx.fill(CGRect(x: 0, y: 0, width: cW, height: cH))

        let scale = min(cW / imgW, cH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let originX = (cW - drawW) / 2
        let originY = (cH - drawH) / 2
        ctx.draw(cgImage, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
    }
}
