import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageLoader {
    /// Camera RAW formats macOS can decode (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, Samsung,
    /// Leica, Hasselblad, Phase One, Sigma and DNG).
    public static let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
                                                     "rw2", "pef", "srw", "3fr", "fff", "erf", "mrw", "x3f", "iiq", "rwl", "mef"]
    public static let extensions: Set<String> = Set(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]).union(rawExtensions)

    public static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    /// SQL: 1 when the path column names a RAW file, else 0 (extensions are 3 letters, "fff"/"iiq" included).
    public static func rawSQL(_ column: String) -> String {
        let list = rawExtensions.map { "'.\($0)'" }.sorted().joined(separator: ",")
        return "(CASE WHEN LOWER(SUBSTR(\(column), -4)) IN (\(list)) THEN 1 ELSE 0 END)"
    }

    /// The JPEG next to a RAW file from a camera shooting both: same folder, same name, another photo extension.
    /// Case-insensitive, so IMG_0001.CR2 pairs with img_0001.jpg.
    public static func pairKey(_ path: String) -> String { ((path as NSString).deletingPathExtension as String).lowercased() }

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
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOptions(for: url) as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (src, data.count)
    }

    /// Options for decoding a file's bytes from memory. The type hint matters for RAW files: without it ImageIO
    /// takes a Sony ARW (a TIFF container) for a plain TIFF and decodes nothing.
    public static func sourceOptions(for url: URL) -> [CFString: Any] {
        var opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) { opts[kCGImageSourceTypeIdentifierHint] = type.identifier }
        return opts
    }

    /// Long side of the image after EXIF orientation is applied.
    public static func pixelLongSide(_ src: CGImageSource) -> Int {
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(w, h)
    }

    /// Upright decode with the long side capped at `maxPixel`. ImageIO uses JPEG DCT scaling when it can. A RAW
    /// file's embedded preview (the camera's own JPEG) is used when it is big enough for `maxPixel`: developing the
    /// RAW data takes seconds per photo and looks no better at these sizes.
    public static func decode(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        if isRawSource(src), let preview = embeddedPreview(src, maxPixel: maxPixel) { return preview }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Upright decode of a file, long side capped at `maxPixel` (nil: the full size; a RAW file is then developed).
    public static func decode(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let long = pixelLongSide(src)
        let side = maxPixel.map { long > 0 ? min($0, long) : $0 } ?? long
        guard side > 0 else { return nil }
        return decode(src, maxPixel: side)
    }

    /// The thumbnail stored in the file by the camera (EXIF), upright, at most `maxPixel`; nil when there is none
    /// (then ImageIO would decode the image, which this never asks for).
    public static func embeddedThumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func isRawSource(_ src: CGImageSource) -> Bool {
        // com.canon.cr2-raw-image, com.nikon.raw-image, com.sony.arw-raw-image, com.adobe.raw-image (DNG)…
        guard let type = CGImageSourceGetType(src) as String? else { return false }
        return type == "public.camera-raw-image" || type.hasSuffix("raw-image")
    }

    /// The preview the camera wrote into a RAW file, if it is at least three quarters of the size wanted (or of the
    /// photo itself, when that is smaller), scaled down to `maxPixel` when it is bigger.
    static func embeddedPreview(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let p = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let long = max(p.width, p.height), wanted = min(maxPixel, max(1, pixelLongSide(src)))
        guard Double(long) >= Double(wanted) * 0.75 else { return nil }
        guard long > maxPixel else { return p }
        let k = Double(maxPixel) / Double(long), w = Int(Double(p.width) * k), h = Int(Double(p.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: p.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return p }
        ctx.interpolationQuality = .high
        ctx.draw(p, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// EXIF capture time (DateTimeOriginal + sub-seconds), if present.
    public static func captureDate(_ src: CGImageSource) -> Date? {
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let exif = p?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let s = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]) as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var date = f.date(from: s)
        if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String, let frac = Double("0." + sub) { date = date?.addingTimeInterval(frac) }
        return date
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dst)
    }
}
