import CoreImage
import CoreVideo
import ImageIO
import AVFoundation

enum CameraResolution: Int, CaseIterable, Identifiable {
    case vga, hd, fullHD
    var id: Int { rawValue }
    var width: Int { [640, 1280, 1920][rawValue] }
    var height: Int { [480, 720, 1080][rawValue] }
    var label: String { ["480p · 640 × 480", "720p · 1280 × 720", "1080p · 1920 × 1080"][rawValue] }
    var preset: AVCaptureSession.Preset { [.vga640x480, .hd1280x720, .hd1920x1080][rawValue] }
}

/// HD travels as standard UVC MJPEG. The host encodes the actual sensor
/// image at the selected size; the guest uses its built-in USB camera driver.
final class CameraFrameEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func blackFrame(_ resolution: CameraResolution) -> Data? {
        encode(CIImage(color: .black), resolution: resolution, fit: false)
    }

    func jpeg(_ pixel: CVPixelBuffer, resolution: CameraResolution, mirrored: Bool = false) -> Data? {
        var image = CIImage(cvPixelBuffer: pixel)
        if mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                tx: image.extent.minX + image.extent.maxX, ty: 0))
        }
        return encode(image, resolution: resolution, fit: true)
    }

    private func encode(_ image: CIImage, resolution: CameraResolution, fit: Bool) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: resolution.width, height: resolution.height)
        var result = CIImage(color: .black).cropped(to: bounds)
        if fit {
            let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
            let dx = (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX
            let dy = (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY
            result = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).composited(over: result)
        }
        return context.jpegRepresentation(of: result.cropped(to: bounds), colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }
}
