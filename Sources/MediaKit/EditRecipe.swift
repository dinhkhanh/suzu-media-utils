import CoreGraphics
import Foundation

/// How an exported photo is edited. Every step is optional; an empty recipe is a plain re-encode.
public struct EditRecipe: Codable, Sendable, Equatable, Hashable {
    /// Core Image auto-enhance (exposure, tone curve, shadows/highlights, vibrance, face-aware balance).
    public var autoTone = false
    /// 0-1 blend between the original and the auto-toned result.
    public var autoToneStrength = 1.0
    /// Face-aware crop to an aspect ratio; nil keeps the frame.
    public var aspect: AspectPreset?
    public var watermark: WatermarkSpec?
    /// Long side in pixels after cropping; nil keeps the size.
    public var maxLongSide: Int?
    public var jpegQuality = 0.9
    /// nil = JPEG.
    public var format: OutputFormat?
    /// Names written into the exported file's metadata (IPTC PersonInImage + keywords).
    public var writePeopleNames = true

    public init() {}

    public var outputFormat: OutputFormat { format ?? .jpeg }
    public var fileExtension: String { outputFormat.fileExtension }

    public var isPassthrough: Bool { !autoTone && aspect == nil && watermark == nil && maxLongSide == nil }
}

public enum OutputFormat: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Small files for sharing; quality slider applies.
    case jpeg
    /// Lossless, in the photo's own colour space, 16 bits per channel when the original has more than 8.
    case png

    public var id: String { rawValue }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var label: String { self == .png ? "PNG" : "JPEG" }
}

public enum AspectPreset: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case square = "1:1"
    case portrait = "4:5"
    case story = "9:16"
    case landscape = "16:9"
    case link = "1.91:1"

    public var id: String { rawValue }
    /// Width / height.
    public var ratio: Double {
        switch self {
        case .square: 1
        case .portrait: 4.0 / 5
        case .story: 9.0 / 16
        case .landscape: 16.0 / 9
        case .link: 1.91
        }
    }
    public var label: String {
        switch self {
        case .square: "Square 1:1 (Instagram)"
        case .portrait: "Portrait 4:5 (Instagram/Facebook)"
        case .story: "Story 9:16 (Stories/TikTok/Reels)"
        case .landscape: "Landscape 16:9 (YouTube)"
        case .link: "Link 1.91:1 (Facebook link)"
        }
    }
    /// Recommended output long side for the platform.
    public var suggestedLongSide: Int {
        switch self {
        case .square: 1080
        case .portrait: 1350
        case .story: 1920
        case .landscape: 1920
        case .link: 1200
        }
    }
}

public struct WatermarkSpec: Codable, Sendable, Equatable, Hashable {
    public enum Position: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
        public var id: String { rawValue }
        public var label: String {
            ["topLeft": "Top left", "top": "Top", "topRight": "Top right", "left": "Left", "center": "Centre",
             "right": "Right", "bottomLeft": "Bottom left", "bottom": "Bottom", "bottomRight": "Bottom right"][rawValue]!
        }
    }

    public enum TextColor: String, Codable, Sendable, CaseIterable { case white, black }

    /// PNG (with transparency) or any image file.
    public var logoPath: String
    public var position: Position = .bottomRight
    /// Mark width as a fraction of the shorter image side, so it looks the same in portrait and landscape.
    public var size = 0.22
    public var opacity = 0.9
    /// Gap from the edges as a fraction of the shorter side.
    public var margin = 0.035
    /// When not empty, the mark is this text (e.g. "© SuZu Media") instead of the logo.
    public var text: String?
    public var textColor: TextColor?
    /// The saved preset this came from (for the editor; rendering ignores it).
    public var presetId: String?

    public init(logoPath: String) { self.logoPath = logoPath }
    public init(text: String) { logoPath = ""; self.text = text; size = 0.3 }

    public var isText: Bool { !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nothing to draw: no logo chosen and no text.
    public var isEmpty: Bool { !isText && logoPath.isEmpty }

    /// Same look, ignoring which preset it came from.
    public func sameLook(as other: WatermarkSpec) -> Bool {
        var a = self, b = other
        a.presetId = nil; b.presetId = nil
        return a == b
    }
}

/// Where the people are, so crops keep them in frame. Rects are normalized, top-left origin.
public struct FocusHint: Sendable {
    public var primary: CGRect?
    public var others: [CGRect]
    public init(primary: CGRect?, others: [CGRect] = []) { self.primary = primary; self.others = others }
}
