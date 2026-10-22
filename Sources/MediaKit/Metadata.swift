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
        guard !names.isEmpty, let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              ["public.jpeg", "public.heic", "public.png", "public.tiff"].contains(type as String) else { return false }
        let meta = peopleMetadata(names, base: CGImageSourceCopyMetadataAtIndex(src, 0, nil))!
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
