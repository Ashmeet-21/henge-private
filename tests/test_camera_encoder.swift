import CoreVideo
import ImageIO
import Foundation

@main
struct CameraEncoderTests {
    static func pixels(width: Int, height: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = data + y * stride + x * 4
                p[0] = x < width / 2 ? 0 : 255
                p[1] = 0
                p[2] = x < width / 2 ? 255 : 0
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func decode(_ data: Data, size: CameraResolution) -> [UInt8] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == size.width && image.height == size.height)
        var rgba = [UInt8](repeating: 0, count: size.width * size.height * 4)
        rgba.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        return rgba
    }

    static func main() throws {
        let encoder = CameraFrameEncoder()
        let landscape = pixels(width: 128, height: 64)
        let fixtureFolder = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder = fixtureFolder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for size in CameraResolution.allCases {
            let dark = encoder.blackFrame(size)!
            precondition(dark.count < 65_536)
            let black = decode(dark, size: size)
            precondition(black[(size.height / 2 * size.width + size.width / 2) * 4] < 5)
            let jpeg = encoder.jpeg(landscape, resolution: size)!
            let image = decode(jpeg, size: size)
            let left = (size.height / 2 * size.width + size.width / 4) * 4
            let right = (size.height / 2 * size.width + 3 * size.width / 4) * 4
            // Asymmetric colors must remain on their original sides.
            precondition(image[left] > 200 && image[left + 2] < 30)
            precondition(image[right + 2] > 200 && image[right] < 30)
            let mirrored = encoder.jpeg(landscape, resolution: size, mirrored: true)!
            let flipped = decode(mirrored, size: size)
            precondition(flipped[left] < 30 && flipped[left + 2] > 200)
            precondition(flipped[right] > 200 && flipped[right + 2] < 30)
            if let folder = fixtureFolder {
                try dark.write(to: folder.appendingPathComponent("black-\(size.rawValue).jpg"))
                try jpeg.write(to: folder.appendingPathComponent("camera-\(size.rawValue).jpg"))
                try mirrored.write(to: folder.appendingPathComponent("camera-mirrored-\(size.rawValue).jpg"))
            }
        }
        let portrait = encoder.jpeg(pixels(width: 64, height: 128), resolution: .hd)!
        let image = decode(portrait, size: .hd)
        let border = (360 * 1280 + 10) * 4
        precondition(image[border] < 5 && image[border + 1] < 5 && image[border + 2] < 5)
        // Match the iOS capture output, including padded NV12 plane strides.
        var nv12: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 130, 74, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nv12) == kCVReturnSuccess)
        let pixel = nv12!
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pixel, 0), 90, CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * 74)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        for y in 0..<37 { for x in stride(from: 0, to: 130, by: 2) { uv[y * uvStride + x] = 85; uv[y * uvStride + x + 1] = 220 } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let native = decode(encoder.jpeg(pixel, resolution: .hd)!, size: .hd)
        let center = (360 * 1280 + 640) * 4
        precondition(native[center] > 100 && native[center] > native[center + 2])
        CVPixelBufferLockBaseAddress(pixel, [])
        for y in 0..<37 { for x in stride(from: 66, to: 130, by: 2) { uv[y * uvStride + x] = 220; uv[y * uvStride + x + 1] = 85 } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let flippedNV12 = decode(encoder.jpeg(pixel, resolution: .hd, mirrored: true)!, size: .hd)
        let left = (360 * 1280 + 320) * 4, right = (360 * 1280 + 960) * 4
        precondition(flippedNV12[left + 2] > 150 && flippedNV12[left] < 80)
        precondition(flippedNV12[right] > 150 && flippedNV12[right + 2] < 80)
        print("Camera encoder: VGA/720p/1080p, NV12, JPEG decoding, black frames, aspect fit, orientation and horizontal flip passed")
    }
}
