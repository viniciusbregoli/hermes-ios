import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO decoding: reads HEIC/PNG/JPEG alike, applies EXIF orientation and never decodes the
/// full-size bitmap, which keeps a 48 MP photo from spiking memory.
public enum ImageFile {
    public static func cgImage(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// About 2048 px on the long edge, as JPEG: plenty for vision models and a few hundred KB to upload.
    public static func jpeg(_ data: Data, maxPixel: Int = 2048) async -> Data? {
        await encoded(data, maxPixel: maxPixel, type: .jpeg)
    }

    /// Same size cap as `jpeg`, but lossless, for images whose transparency would turn black in a JPEG.
    public static func png(_ data: Data, maxPixel: Int = 2048) async -> Data? {
        await encoded(data, maxPixel: maxPixel, type: .png)
    }

    /// Whether the file has an alpha channel (it can still be fully opaque).
    public static func hasAlpha(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    private static func encoded(_ data: Data, maxPixel: Int, type: UTType) async -> Data? {
        await Task.detached {
            guard let image = cgImage(data, maxPixel: maxPixel) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
            let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
            CGImageDestinationAddImage(dest, image, options as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }.value
    }
}
