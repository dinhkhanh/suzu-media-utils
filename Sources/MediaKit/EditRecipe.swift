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
    /// Light, colour, detail and orientation (see Adjustments); nil is none.
    public var adjustments: Adjustments?
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

    public var isPassthrough: Bool {
        !autoTone && !crops && watermark == nil && maxLongSide == nil && straighten != true && rotation == nil && look.isEmpty
    }

    /// The adjustments, empty when none.
    public var look: Adjustments {
        get { adjustments ?? Adjustments() }
        set { adjustments = newValue.isEmpty ? nil : newValue }
    }

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

/// The dials of a quick edit, as in any photo editor: light, colour, detail, and which way up the photo is. Every
/// value is 0 (or false) when it does nothing, so an empty set of adjustments is skipped.
public struct Adjustments: Codable, Sendable, Equatable, Hashable {
    // Light (-1…1; exposure in stops, -2…2)
    public var exposure = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    // Colour (-1…1)
    public var temperature = 0.0
    public var tint = 0.0
    public var vibrance = 0.0
    public var saturation = 0.0
    public var monochrome = false
    // Detail (0…1)
    public var sharpness = 0.0
    public var clarity = 0.0
    public var vignette = 0.0
    /// Tone curve: the output of the inputs 0, ¼, ½, ¾ and 1 (nil is the straight line). Applied after the light.
    public var curve: [Double]?
    /// Hue, saturation and luminance per colour (see HSLAdjust); nil is none.
    public var hsl: HSLAdjust?
    /// Quarter turns clockwise (0…3), applied before anything else.
    public var turns = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init() {}

    /// Saved by older versions without some of the keys: those keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        curve = try c.decodeIfPresent([Double].self, forKey: .curve)
        if curve?.count != 5 || curve == Adjustments.straightCurve { curve = nil }
        hsl = try c.decodeIfPresent(HSLAdjust.self, forKey: .hsl)
        if hsl?.isEmpty == true { hsl = nil }
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
    }

    public var isEmpty: Bool { !changesPixels && !changesOrientation }
    /// Light, colour or detail set.
    public var changesPixels: Bool {
        exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0 || temperature != 0 || tint != 0 || vibrance != 0
            || saturation != 0 || monochrome || sharpness != 0 || clarity != 0 || vignette != 0 || hasCurve || hsl?.isEmpty == false
    }
    public static let straightCurve = [0.0, 0.25, 0.5, 0.75, 1.0]
    public var hasCurve: Bool { curve.map { $0.count == 5 && $0 != Adjustments.straightCurve } ?? false }
    /// The curve's points, straight when none is set; setting the straight line clears it.
    public var tone: [Double] {
        get { curve?.count == 5 ? curve! : Adjustments.straightCurve }
        set { curve = newValue.count == 5 && newValue != Adjustments.straightCurve ? newValue : nil }
    }
    public var colours: HSLAdjust {
        get { hsl ?? HSLAdjust() }
        set { hsl = newValue.isEmpty ? nil : newValue }
    }
    public var changesOrientation: Bool { turns % 4 != 0 || flipHorizontal || flipVertical }
    /// The photo ends up the other way round (taller instead of wider).
    public var swapsSides: Bool { turns % 2 != 0 }

    /// The light, colour and detail of `other` with this one's orientation.
    public func withLook(of other: Adjustments) -> Adjustments {
        var a = other
        a.turns = turns; a.flipHorizontal = flipHorizontal; a.flipVertical = flipVertical
        return a
    }

    /// Only the orientation.
    public var orientationOnly: Adjustments {
        var a = Adjustments()
        a.turns = turns; a.flipHorizontal = flipHorizontal; a.flipVertical = flipVertical
        return a
    }

    /// Where a normalized, top-left-origin rect of the photo as shot ends up after the flips and turns.
    public func map(_ r: CGRect) -> CGRect {
        var x = r.minX, y = r.minY, w = r.width, h = r.height
        if flipHorizontal { x = 1 - x - w }
        if flipVertical { y = 1 - y - h }
        for _ in 0..<((turns % 4 + 4) % 4) { (x, y, w, h) = (1 - y - h, x, h, w) }  // a quarter turn clockwise
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Hue, saturation and luminance of eight colours (red, orange, yellow, green, aqua, blue, purple, magenta), each
/// -1…1, as the HSL panel of any editor. Applied as a colour cube (see EditPipeline.hslCube).
public struct HSLAdjust: Codable, Sendable, Equatable, Hashable {
    public static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    /// Hue of each band's centre, degrees.
    public static let hues: [Double] = [0, 30, 60, 120, 180, 240, 275, 310]
    public var hue = [Double](repeating: 0, count: 8)
    public var saturation = [Double](repeating: 0, count: 8)
    public var luminance = [Double](repeating: 0, count: 8)

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func eight(_ k: CodingKeys) throws -> [Double] {
            let v = try c.decodeIfPresent([Double].self, forKey: k) ?? []
            return v.count == 8 ? v : [Double](repeating: 0, count: 8)
        }
        hue = try eight(.hue); saturation = try eight(.saturation); luminance = try eight(.luminance)
    }

    public var isEmpty: Bool { hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } && luminance.allSatisfy { $0 == 0 } }
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
    /// A crop drawn by hand (normalized, top-left origin, of the levelled photo): used as it is, whatever shape.
    public var rect: CGRect?
    public init(primary: CGRect?, others: [CGRect] = [], center: CGPoint? = nil, zoom: Double? = nil, rect: CGRect? = nil) {
        self.primary = primary; self.others = others; self.center = center; self.zoom = zoom; self.rect = rect
    }
    /// Nothing known about the people in the photo (only a hand-set crop, if that).
    public var hasNoFaces: Bool { primary == nil && others.isEmpty }
    /// The crop's magnification, at least 1.
    public var magnification: Double { max(1, zoom ?? 1) }
}
