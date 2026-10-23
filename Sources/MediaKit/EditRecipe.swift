import CoreGraphics
import Foundation

/// How an exported photo is edited. Every step is optional; an empty recipe is a plain re-encode.
public struct EditRecipe: Codable, Sendable, Equatable, Hashable {
    /// Core Image auto-enhance (exposure, tone curve, shadows/highlights, vibrance, face-aware balance).
    public var autoTone = false
    /// 0-1 blend between the original and the auto-toned result.
    public var autoToneStrength = 1.0
    /// Level a tilted photo (0.3°–10° off, by its vertical lines), trimming the corners the turn leaves.
    public var straighten: Bool?
    /// Degrees to turn the photo counter-clockwise, set by hand for one photo (see CropPlacements); wins over
    /// `straighten`. 0 turns it off for that photo.
    public var rotation: Double?
    /// Face-aware crop to an aspect ratio; nil keeps the frame. With `cropByOrientation`, for landscape and square
    /// photos only.
    public var aspect: AspectPreset?
    /// Portrait photos (taller than wide) get `portraitAspect` instead, so one export can send portraits out as 4:5
    /// and landscapes as 16:9.
    public var cropByOrientation: Bool?
    /// Crop for portrait photos when cropping by orientation; nil keeps their frame.
    public var portraitAspect: AspectPreset?
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

    public var isPassthrough: Bool { !autoTone && !crops && watermark == nil && maxLongSide == nil && straighten != true && rotation == nil }

    /// Some photos get cropped.
    public var crops: Bool { aspect != nil || (cropByOrientation == true && portraitAspect != nil) }

    /// The crop for a photo of this (upright) size.
    public func aspect(for size: CGSize) -> AspectPreset? {
        cropByOrientation == true && size.height > size.width ? portraitAspect : aspect
    }

    /// "4:5 crop", or "4:5 portraits, 16:9 landscapes"; nil without a crop.
    public var cropDescription: String? {
        guard cropByOrientation == true else { return aspect.map { "\($0.rawValue) crop" } }
        guard crops else { return nil }
        return "\(portraitAspect?.rawValue ?? "original") portraits, \(aspect?.rawValue ?? "original") landscapes"
    }
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
    /// Output long side for crops: Facebook shows photos up to 2048 px on the long side without shrinking them, and the
    /// other networks scale down from it.
    public static let socialLongSide = 2048
    /// The platform's own display size (Instagram feed 1080 px wide, Stories 1080 x 1920...), for posting only there.
    public var platformLongSide: Int {
        switch self {
        case .square: 1080
        case .portrait: 1350
        case .story: 1920
        case .landscape: 1920
        case .link: 1200
        }
    }
    public var platformName: String {
        switch self {
        case .square, .portrait: "Instagram"
        case .story: "Stories"
        case .landscape: "YouTube"
        case .link: "link preview"
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
    /// A bar across the whole width (e.g. an event banner) instead of a small mark: `logoPath` is the banner for
    /// landscape and square photos, `portraitLogoPath` the one for portrait photos. It is `bannerHeight` high whatever
    /// the photo's shape, centred, with its sides trimmed to the photo's width. The position's row picks top, middle
    /// or bottom; size is ignored.
    public var banner: Bool?
    /// Banner for photos taller than wide; nil or empty uses `logoPath` (and the other way round).
    public var portraitLogoPath: String?
    /// Banner height as a share of the photo's long side; nil is `defaultBannerHeight`.
    public var bannerHeight: Double?
    /// 112 px on a photo 2048 px on the long side.
    public static let defaultBannerHeight = 112.0 / 2048
    /// Long side the banner height is shown against in the editor.
    public static let bannerReferenceSide = 2048.0
    /// The saved preset this came from (for the editor; rendering ignores it).
    public var presetId: String?

    public init(logoPath: String) { self.logoPath = logoPath }
    public init(text: String) { logoPath = ""; self.text = text; size = 0.3 }
    public init(banner landscape: String, portrait: String? = nil) {
        logoPath = landscape
        portraitLogoPath = portrait
        banner = true
        position = .bottom
        opacity = 1
        margin = 0
    }

    public var isBanner: Bool { banner == true && !isText }
    public var isText: Bool { !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nothing to draw: no logo chosen and no text.
    public var isEmpty: Bool { !isText && logoPath.isEmpty && (!isBanner || (portraitLogoPath ?? "").isEmpty) }

    /// The image file drawn on a photo of this size (banners have one per orientation).
    public func logoPath(for size: CGSize) -> String {
        guard isBanner else { return logoPath }
        let portrait = portraitLogoPath ?? ""
        if size.height > size.width { return portrait.isEmpty ? logoPath : portrait }
        return logoPath.isEmpty ? portrait : logoPath
    }

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
    /// Crop centre placed by hand (normalized); wins over the faces.
    public var center: CGPoint?
    /// Zoom set by hand: the crop is 1/zoom of the largest one that fits (1 or nil: the largest). Trims the edges
    /// of a photo even when it keeps its shape.
    public var zoom: Double?
    public init(primary: CGRect?, others: [CGRect] = [], center: CGPoint? = nil, zoom: Double? = nil) {
        self.primary = primary; self.others = others; self.center = center; self.zoom = zoom
    }
    /// Nothing known about the people in the photo (only a hand-set crop, if that).
    public var hasNoFaces: Bool { primary == nil && others.isEmpty }
    /// The crop's magnification, at least 1.
    public var magnification: Double { max(1, zoom ?? 1) }
}
