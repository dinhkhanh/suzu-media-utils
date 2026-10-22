import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoader {
    public static let extensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    /// Recursively lists image and video files under `root`, sorted by path. Skips hidden files and AppleDouble `._*` files.
    public static func enumerate(_ root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        let wanted = extensions.union(VideoSampler.extensions)
        for case let url as URL in e
        where wanted.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._") {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Reads the whole file in one sequential read (one round trip on network shares), then decodes from memory.
    public static func source(_ url: URL) throws -> (CGImageSource, Int) {
        let data = try Data(contentsOf: url, options: .uncached)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (src, data.count)
    }

    /// Long side of the image after EXIF orientation is applied.
    public static func pixelLongSide(_ src: CGImageSource) -> Int {
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(w, h)
    }

    /// Upright decode with the long side capped at `maxPixel`. ImageIO uses JPEG DCT scaling when it can.
    public static func decode(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dst)
    }
}
