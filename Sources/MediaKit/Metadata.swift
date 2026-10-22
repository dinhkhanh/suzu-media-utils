import CoreGraphics
import FaceCore
import Foundation
import ImageIO

/// Writes people's names into image metadata so Lightroom, Photo Mechanic, Bridge and Apple Photos can see them:
/// XMP Iptc4xmpExt:PersonInImage and dc:subject keywords, plus legacy IPTC keywords.
public enum Metadata {
    static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString

    static func peopleMetadata(_ names: [String], base: CGImageMetadata? = nil) -> CGImageMetadata? {
        let meta = base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, iptcExt, "Iptc4xmpExt" as CFString, nil)
        let unique = Array(NSOrderedSet(array: names)) as! [String]
        func merged(_ path: String) -> [String] {
            let existing = (CGImageMetadataCopyTagWithPath(meta, nil, path as CFString)
                .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] } ?? [])
                .compactMap { CGImageMetadataTagCopyValue($0) as? String }
            return Array(NSOrderedSet(array: existing + unique)) as! [String]
        }
        guard let person = CGImageMetadataTagCreate(iptcExt, "Iptc4xmpExt" as CFString, "PersonInImage" as CFString, .arrayUnordered,
                                                    merged("Iptc4xmpExt:PersonInImage") as CFArray),
              let subject = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                     "subject" as CFString, .arrayUnordered, merged("dc:subject") as CFArray)
        else { return nil }
        CGImageMetadataSetTagWithPath(meta, nil, "Iptc4xmpExt:PersonInImage" as CFString, person)
        CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, subject)
        return meta
    }

    /// Adds names to a JPEG/HEIC/PNG/TIFF in place without re-encoding the pixels. Returns false for formats that
    /// can't carry it (videos, RAW).
    @discardableResult
    public static func writePeople(_ names: [String], to url: URL) throws -> Bool {
        guard !names.isEmpty else { return false }
        return try rewrite(url) { peopleMetadata(names, base: $0) }
    }

    /// xmp:Rating (0-5 stars, -1 = rejected, as Bridge writes it) and xmp:Label ("Red"…, "" = none), which Lightroom,
    /// Bridge and Photo Mechanic read.
    static func ratingMetadata(_ rating: Int, label: String?) -> CGImageMetadata? {
        let meta = CGImageMetadataCreateMutable()
        guard let r = CGImageMetadataTagCreate(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "Rating" as CFString,
                                               .string, String(max(-1, min(5, rating))) as CFString),
              let l = CGImageMetadataTagCreate(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "Label" as CFString,
                                               .string, (label ?? "") as CFString)
        else { return nil }
        CGImageMetadataSetTagWithPath(meta, nil, "xmp:Rating" as CFString, r)
        CGImageMetadataSetTagWithPath(meta, nil, "xmp:Label" as CFString, l)
        return meta
    }

    /// Writes a rating and colour label into a JPEG/HEIC/PNG/TIFF in place without re-encoding the pixels. Returns
    /// false for formats that can't carry it (videos, RAW).
    @discardableResult
    public static func writeRating(_ rating: Int, label: String?, to url: URL) throws -> Bool {
        try rewrite(url) { _ in ratingMetadata(rating, label: label) }
    }

    /// The rating and label in a file's XMP, if any.
    public static func rating(in url: URL) -> (rating: Int?, label: String?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return (nil, nil) }
        func value(_ path: String) -> String? {
            CGImageMetadataCopyTagWithPath(meta, nil, path as CFString).flatMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        return (value("xmp:Rating").flatMap { Int($0) }, value("xmp:Label"))
    }

    /// Merges `metadata(existing)` into the file through a temporary file next to it, keeping the pixels as they are.
    static func rewrite(_ url: URL, metadata: (CGImageMetadata?) -> CGImageMetadata?) throws -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              ["public.jpeg", "public.heic", "public.png", "public.tiff"].contains(type as String),
              let meta = metadata(CGImageSourceCopyMetadataAtIndex(src, 0, nil)) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        var err: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dst, src, [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true] as CFDictionary, &err)
        guard ok else {
            try? FileManager.default.removeItem(at: tmp)
            throw err?.takeRetainedValue() ?? CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    }

    /// Names already in a file's metadata (PersonInImage).
    public static func people(in url: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(meta, nil, "Iptc4xmpExt:PersonInImage" as CFString),
              let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// EXIF capture time, if any.
    public static func captureDate(_ src: CGImageSource) -> Date? { ImageLoader.captureDate(src) }
}
