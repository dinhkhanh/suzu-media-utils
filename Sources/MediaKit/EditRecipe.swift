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
    /// Skin retouch and the people's parts (face skin, body skin, lips, clothes) found in each photo and adjusted on
    /// their own (see Retouch); nil is none.
    public var retouch: Retouch?
    /// Strokes painted by hand on the parts' masks of one photo (see MaskStroke): filled in from the photo's own
    /// edits (CropPlacements) when it is rendered, never set on a recipe shared by several photos.
    public var brush: [Retouch.Part: [MaskStroke]]?
    /// Strokes of the healing brush on one photo (see HealStroke), filled in as `brush` is.
    public var heal: [HealStroke]?
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
            && !(retouch?.isActive ?? false) && (heal ?? []).isEmpty
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

/// What the people in a photo get on their own: skin made smoother, brighter and fairer, and each part found in the
/// photo (face skin, body skin, lips, clothes) with dials of its own. The parts are found again in every photo, so
/// one setting suits a whole batch.
public struct Retouch: Codable, Sendable, Equatable, Hashable {
    public enum Part: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable, Identifiable, Hashable {
        case faceSkin, bodySkin, lips, clothes
        /// Where the skin retouch (smooth, brighten, whiten) goes: face skin, and body skin with `bodyToo`. It has
        /// no dials of its own, only its mask (shown and painted like the parts').
        case skin
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .faceSkin: "Face skin"
            case .bodySkin: "Body skin"
            case .lips: "Lips"
            case .clothes: "Clothes"
            case .skin: "Skin retouch"
            }
        }
        /// The parts with dials of their own.
        public static let dialled: [Part] = [.faceSkin, .bodySkin, .lips, .clothes]
    }

    /// Skin smoothed (blemishes and texture softened, edges kept), 0…1.
    public var smooth = 0.0
    /// Skin made brighter, 0…1.
    public var brighten = 0.0
    /// Skin made fairer: less yellow and less saturated, a touch lighter, 0…1.
    public var whiten = 0.0
    /// The skin retouch on body skin too (arms, legs, neck), not only faces.
    public var bodyToo = true
    /// Each part's own dials; a part not here is left alone.
    public var parts: [Part: PartLook] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smooth = try c.decodeIfPresent(Double.self, forKey: .smooth) ?? 0
        brighten = try c.decodeIfPresent(Double.self, forKey: .brighten) ?? 0
        whiten = try c.decodeIfPresent(Double.self, forKey: .whiten) ?? 0
        bodyToo = try c.decodeIfPresent(Bool.self, forKey: .bodyToo) ?? true
        parts = try c.decodeIfPresent([Part: PartLook].self, forKey: .parts) ?? [:]
    }

    public var retouchesSkin: Bool { smooth != 0 || brighten != 0 || whiten != 0 }
    public var isActive: Bool { retouchesSkin || parts.values.contains { $0.changesPixels } }

    public func look(_ part: Part) -> PartLook { parts[part] ?? PartLook() }
    public mutating func setLook(_ look: PartLook, for part: Part) {
        // Kept while only its mask's edge is set, so the edge isn't lost while the dials are at 0.
        parts[part] = look == PartLook() ? nil : look
    }
}

/// One part's dials, and how its mask is drawn.
public struct PartLook: Codable, Sendable, Equatable, Hashable {
    /// Stops, -2…2.
    public var exposure = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var temperature = 0.0
    public var tint = 0.0
    /// Turns the colours, -1…1 = ±60°.
    public var hue = 0.0
    /// The mask's edge: 0 hard, 1 very soft.
    public var softness = 0.3
    /// The mask grown (> 0) or shrunk (< 0), -1…1.
    public var grow = 0.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.3
        grow = try c.decodeIfPresent(Double.self, forKey: .grow) ?? 0
    }

    public var changesPixels: Bool { exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0 || tint != 0 || hue != 0 }
}

/// The dials of a quick edit, as in any photo editor: light, colour, detail, and which way up the photo is. Every
/// value is 0 (or false) when it does nothing, so an empty set of adjustments is skipped.
public struct Adjustments: Codable, Sendable, Equatable, Hashable {
    // Light (-1…1; exposure in stops, -2…2)
    public var exposure = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    /// The brightest tones pushed towards white (or held back from it), and the darkest towards black (or lifted).
    public var whites = 0.0
    public var blacks = 0.0
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
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
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
        exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0 || temperature != 0 || tint != 0 || vibrance != 0
            || saturation != 0 || monochrome || sharpness != 0 || clarity != 0 || vignette != 0 || hasCurve || hsl?.isEmpty == false
    }
    public static let straightCurve = [0.0, 0.25, 0.5, 0.75, 1.0]
    public var hasCurve: Bool { curve.map { $0.count == 5 && $0 != Adjustments.straightCurve } ?? false }
    /// The curve's points, straight when none is set; setting the straight line (to within rounding, as a curve
    /// unwound from itself comes back) clears it.
    public var tone: [Double] {
        get { curve?.count == 5 ? curve! : Adjustments.straightCurve }
        set {
            let straight = zip(newValue, Adjustments.straightCurve).allSatisfy { abs($0 - $1) < 1e-9 }
            curve = newValue.count == 5 && !straight ? newValue : nil
        }
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

    /// The sliders scaled towards nothing (0 = none, 1 = as is) and the curve pulled towards the straight line:
    /// the strength of an auto tone. Orientation, black & white and HSL are kept.
    public func scaled(_ k: Double) -> Adjustments {
        var a = self
        a.exposure *= k; a.contrast *= k; a.highlights *= k; a.shadows *= k; a.whites *= k; a.blacks *= k
        a.temperature *= k; a.tint *= k; a.vibrance *= k; a.saturation *= k
        a.sharpness *= k; a.clarity *= k; a.vignette *= k
        if hasCurve { a.tone = zip(tone, Adjustments.straightCurve).map { $1 + ($0 - $1) * k } }
        return a
    }

    /// This look on top of `base` (what auto tone set): sliders add up, this curve follows the base's; black &
    /// white, HSL, detail and orientation are this look's. What the editor shows and the pipeline applies.
    public func composed(over base: Adjustments?) -> Adjustments {
        guard let base else { return self }
        var a = self
        a.exposure = (exposure + base.exposure).clamped(-2, 2)
        a.contrast = (contrast + base.contrast).clamped(-1, 1)
        a.highlights = (highlights + base.highlights).clamped(-1, 1)
        a.shadows = (shadows + base.shadows).clamped(-1, 1)
        a.whites = (whites + base.whites).clamped(-1, 1)
        a.blacks = (blacks + base.blacks).clamped(-1, 1)
        a.temperature = (temperature + base.temperature).clamped(-1, 1)
        a.tint = (tint + base.tint).clamped(-1, 1)
        a.vibrance = (vibrance + base.vibrance).clamped(-1, 1)
        a.saturation = (saturation + base.saturation).clamped(-1, 1)
        if base.hasCurve { a.tone = Adjustments.compose(outer: tone, inner: base.tone) }
        return a
    }

    /// The look that, composed over `base`, gives this one: what was set on top of auto tone. Inverse of `composed`.
    public func subtracting(_ base: Adjustments?) -> Adjustments {
        guard let base else { return self }
        var a = self
        a.exposure -= base.exposure; a.contrast -= base.contrast; a.highlights -= base.highlights; a.shadows -= base.shadows
        a.whites -= base.whites; a.blacks -= base.blacks
        a.temperature -= base.temperature; a.tint -= base.tint; a.vibrance -= base.vibrance; a.saturation -= base.saturation
        if base.hasCurve { a.tone = Adjustments.unwind(tone, inner: base.tone) }
        return a
    }

    /// outer(inner(x)) at the five nodes.
    public static func compose(outer: [Double], inner: [Double]) -> [Double] {
        straightCurve.map { x in min(1, max(0, Adjustments.curveValue(outer, Adjustments.curveValue(inner, x)))) }
    }

    /// The outer curve of a composition: `shown` = outer ∘ inner, so outer(t) = shown(inner⁻¹(t)).
    public static func unwind(_ shown: [Double], inner: [Double]) -> [Double] {
        straightCurve.map { t in
            // inner is monotone: bisect for the x with inner(x) = t.
            var lo = 0.0, hi = 1.0
            if Adjustments.curveValue(inner, 0) >= t { return min(1, max(0, Adjustments.curveValue(shown, 0))) }
            if Adjustments.curveValue(inner, 1) <= t { return min(1, max(0, Adjustments.curveValue(shown, 1))) }
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if Adjustments.curveValue(inner, mid) < t { lo = mid } else { hi = mid }
            }
            return min(1, max(0, Adjustments.curveValue(shown, (lo + hi) / 2)))
        }
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
    /// The text's font, by PostScript name (one face: family and style); nil is `defaultFont`.
    public var font: String?
    public static let defaultFont = "HelveticaNeue-Medium"
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
    /// A line of text drawn as well as the logo or banner (e.g. "© SuZu Media" with the event's banner), in its own
    /// place. Ignored on a text watermark, which is text already.
    public var extraText: TextMark?

    /// Text to go with a logo or banner: the same choices as a text watermark.
    public struct TextMark: Codable, Sendable, Equatable, Hashable {
        public var text: String
        public var position: Position
        public var size = 0.25
        public var opacity = 0.9
        public var margin = 0.035
        public var textColor: TextColor?
        /// PostScript name; nil is `WatermarkSpec.defaultFont`.
        public var font: String?
        /// Turned off: not drawn, but kept, so turning it on again brings it back as it was.
        public var off: Bool?
        /// The text preset it came from (for the editor; rendering ignores it).
        public var presetId: String?

        public init(text: String, position: Position) { self.text = text; self.position = position }

        /// The look of a text watermark (a text preset), to go with a logo or banner.
        public init(_ spec: WatermarkSpec) {
            text = spec.text ?? ""
            position = spec.position; size = spec.size; opacity = spec.opacity; margin = spec.margin
            textColor = spec.textColor; font = spec.font; presetId = spec.presetId
        }

        public var isShown: Bool { off != true && !text.trimmingCharacters(in: .whitespaces).isEmpty }

        /// Same look as a text watermark (a preset's), whichever preset it came from and whether it is on.
        public func sameLook(as spec: WatermarkSpec) -> Bool {
            var a = self, b = TextMark(spec)
            a.off = nil; a.presetId = nil; b.presetId = nil
            return a == b
        }

        /// Drawn as a text watermark of its own.
        public var spec: WatermarkSpec {
            var s = WatermarkSpec(text: text)
            s.position = position; s.size = size; s.opacity = opacity; s.margin = margin; s.textColor = textColor; s.font = font
            return s
        }
    }

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
    /// Nothing to draw: no logo chosen and no text, of its own or as well.
    public var isEmpty: Bool { !hasMark && !(extraText?.isShown ?? false) }
    /// The logo, text or banner itself has something to draw (not counting `extraText`).
    public var hasMark: Bool { isText || !logoPath.isEmpty || (isBanner && !(portraitLogoPath ?? "").isEmpty) }
    /// The text drawn as well as the logo or banner, when there is one.
    public var shownExtraText: TextMark? { isText ? nil : extraText.flatMap { $0.isShown ? $0 : nil } }

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

extension Adjustments {
    /// The pipeline's tone curve (monotone cubic through the five points) at `x`.
    public static func curveValue(_ points: [Double], _ x: Double) -> Double { EditPipeline.curveValue(points, x) }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
