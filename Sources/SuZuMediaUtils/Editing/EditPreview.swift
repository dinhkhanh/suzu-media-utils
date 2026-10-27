import AppKit
import CoreImage
import FaceCore
import ImageIO
import MediaKit
import SwiftUI

/// Decoded preview photos (about 1600 px, and up to 5000 px for the one being zoomed into), so switching edits or
/// flipping between a few photos is instant.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    static let context = CIContext(options: [.cacheIntermediates: false])
    /// Long side of the quick decode every photo gets.
    static let baseSide = 1600
    /// Long side of the detailed decode a zoomed-in photo gets (its own size when smaller).
    static let detailSide = 5000

    struct Entry {
        var image: CGImage
        /// Full-size pixel dimensions, upright (for the output size shown under the preview).
        var pixelSize: CGSize
        /// Faces found in the photo, for crops of photos that aren't in the library.
        var detected: FocusHint?
        var detectedDone = false
        /// The tilt straightening would level (degrees counter-clockwise).
        var tilt: Double?
        var tiltDone = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// The two most recent detailed decodes (they are big).
    private var details: [String: CGImage] = [:]
    private var detailOrder: [String] = []

    func entry(_ url: URL) -> Entry? {
        if let e = lock.withLock({ entries[url.path] }) { return e }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = ImageLoader.decode(src, maxPixel: Self.baseSide) else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var w = Double(p?[kCGImagePropertyPixelWidth] as? Int ?? cg.width), h = Double(p?[kCGImagePropertyPixelHeight] as? Int ?? cg.height)
        if let o = p?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let e = Entry(image: cg, pixelSize: CGSize(width: w, height: h))
        store(url.path, e)
        return e
    }

    /// The photo at up to `detailSide`, for zoomed-in previews; the quick decode when the photo isn't bigger.
    func detail(_ url: URL) -> CGImage? {
        if let d = lock.withLock({ details[url.path] }) { return d }
        guard let e = entry(url) else { return nil }
        if max(e.pixelSize.width, e.pixelSize.height) <= Double(Self.baseSide) * 1.2 { return e.image }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = ImageLoader.decode(src, maxPixel: Self.detailSide) else { return nil }
        lock.withLock {
            if details[url.path] == nil { detailOrder.append(url.path) }
            details[url.path] = cg
            while detailOrder.count > 2 { details[detailOrder.removeFirst()] = nil }
        }
        return cg
    }

    func focus(_ url: URL, given: FocusHint?) -> FocusHint? {
        if let given { return given }
        guard var e = entry(url) else { return nil }
        if !e.detectedDone {
            e.detected = EditPipeline.detectFaces(CIImage(cgImage: e.image))
            e.detectedDone = true
            store(url.path, e)
        }
        return e.detected
    }

    func tilt(_ url: URL) -> Double? {
        guard var e = entry(url) else { return nil }
        if !e.tiltDone {
            e.tilt = EditPipeline.horizonTilt(CIImage(cgImage: e.image))
            e.tiltDone = true
            store(url.path, e)
        }
        return e.tilt
    }

    private func store(_ key: String, _ e: Entry) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = e
            while order.count > 12 { entries[order.removeFirst()] = nil }
        }
    }

    struct Rendered {
        var image: NSImage
        var outputSize: CGSize
        var warning: String?
        /// Where the crop sits (normalized, top-left origin) in the levelled photo, for the crop tool.
        var crop: CGRect?
        /// The whole photo, the right way up, toned and levelled: what the crop tool shows.
        var full: NSImage?
        /// `full`'s size in output pixels.
        var fullSize: CGSize
        /// Full-size pixel dimensions, upright.
        var pixelSize: CGSize
        /// The turn applied (degrees counter-clockwise), when straightened.
        var angle: Double?
        /// The turn straightening would make on its own (degrees counter-clockwise).
        var autoAngle: Double?
        /// The people's parts (the masks): found (true), nobody found (false), not looked for (nil).
        var masks: Bool? = nil
    }

    /// The photo through the recipe (or untouched), plus the size the exported file will have. The photo's own crop
    /// (edited by hand) wins over the recipe's, as in the export. `longSide`: the screen pixels the preview gets, so
    /// the result (and its watermark) is drawn at the screen's resolution; `withFull` also renders the whole photo
    /// for the crop tool. `findMasks`: the people's parts are looked for (slow: only when asked, Find Masks); without
    /// them the photo shows no retouch and no mask.
    func render(_ item: ToolItem, recipe: EditRecipe, original: Bool, longSide: Int, withFull: Bool, showMask: Retouch.Part? = nil,
                findMasks: Bool = false) -> Rendered? {
        guard let e = entry(item.url) else { return nil }
        let recipe = CropPlacements.shared.recipe(recipe, for: item.url)
        let edit = CropPlacements.shared.edit(for: item.url)
        let zoom = edit?.zoom, rect = edit?.rect, placed = edit?.center
        // A tighter crop, or a closer look, needs more pixels than the quick decode has.
        let tight = rect.map { max($0.width, $0.height) < 0.8 } ?? ((zoom ?? 1) > 1.25)
        let base = !original && (tight || longSide > Self.baseSide) ? (detail(item.url) ?? e.image) : (longSide > Self.baseSide ? detail(item.url) ?? e.image : e.image)
        var pixelSize = e.pixelSize
        if recipe.look.swapsSides { pixelSize = CGSize(width: pixelSize.height, height: pixelSize.width) }
        if original {
            return Rendered(image: NSImage(cgImage: base, size: .zero), outputSize: e.pixelSize, crop: nil, full: nil,
                            fullSize: e.pixelSize, pixelSize: e.pixelSize, angle: nil, autoAngle: nil)
        }
        var r = recipe
        r.maxLongSide = nil
        var warning: String?
        // Healed first, on the photo as shot; the strokes healed before are kept for this picture.
        let input = Healing.apply(r.heal ?? [], to: CIImage(cgImage: base), key: "\(item.url.path)|\(base.width)x\(base.height)",
                                  amount: r.healAmount ?? 1)
        // The right way up first, then levelled, then toned: the crop, and the photo under it, are of that photo.
        let wantsFaces = (r.aspect(for: pixelSize) != nil || zoom != nil) && placed == nil && rect == nil
        var faces: FocusHint? = wantsFaces ? self.focus(item.url, given: item.focus) : nil
        let (oriented, orientedFaces) = EditPipeline.orient(input, r.look, focus: faces)
        faces = orientedFaces
        let autoAngle = r.straighten == true || r.rotation != nil ? tilt(item.url).map { -$0 } : nil
        var level = oriented, angle: Double?
        if let a = r.rotation ?? (r.straighten == true ? autoAngle : nil), abs(a) >= 0.01 {
            angle = a
            (level, faces) = EditPipeline.rotate(oriented, degrees: a, focus: faces)
        }
        // Auto tone's dials for this photo, kept for the controls to show (and edit from).
        let auto = r.autoTone ? EditPipeline.autoAdjustments(level, strength: r.autoToneStrength) : nil
        let autoKey = item.url.path
        Task { @MainActor in AutoToneValues.shared.set(auto, for: autoKey) }
        // The masks are found on the levelled photo here; the strokes painted on them are placed to match.
        let levelled = angle.map { (degrees: $0, size: oriented.extent.size) }
        // Known by the file and its turn, so zooming in (a bigger decode) doesn't look for them all over again.
        let partsKey = "\(item.url.path)|\(r.look.turns)|\(r.look.flipHorizontal)|\(r.look.flipVertical)|\(angle ?? 0)"
        let parts = findMasks ? BodyParts.find(in: level, key: partsKey) : nil
        var toned = EditPipeline.tone(level, r, auto: auto, levelled: levelled, findParts: { _ in parts })
        // Show Mask: the part's mask, shaped by its dials and painted by hand, tinted red over the photo.
        if let part = showMask, let parts {
            let brush = EditPipeline.placedBrush(r, levelled: levelled)
            let mask = EditPipeline.partMask(part, r.retouch, parts: parts, extent: level.extent, brush: brush)
            let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.6)).cropped(to: level.extent)
            toned = red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: toned, kCIInputMaskImageKey: mask])
        }
        r.straighten = nil
        r.rotation = nil
        r.autoTone = false
        r.adjustments = nil
        r.retouch = nil
        r.brush = nil
        r.heal = nil
        r.healAmount = nil
        var crop: CGRect?, focus: FocusHint?
        let size = level.extent.size
        if let ratio = EditPipeline.cropRatio(r, size: size, focus: FocusHint(primary: nil, zoom: zoom, rect: rect)) {
            // A crop drawn or placed by hand needs no faces; one only zoomed by hand is placed by the faces.
            var f = rect != nil ? FocusHint(primary: nil) : placed.map { FocusHint(primary: nil, center: $0) } ?? faces ?? FocusHint(primary: nil)
            f.zoom = zoom
            f.rect = rect
            focus = f
            let c = EditPipeline.cropRect(imageSize: size, ratio: ratio, focus: focus)
            crop = CGRect(x: c.minX / size.width, y: c.minY / size.height, width: c.width / size.width, height: c.height / size.height)
        }
        var out: CIImage
        do { out = try EditPipeline.apply(r, to: toned, focus: focus, previewLongSide: longSide) } catch {
            warning = "The watermark logo can't be read: choose it again"
            r.watermark = nil
            out = (try? EditPipeline.apply(r, to: toned, focus: focus, previewLongSide: longSide)) ?? toned
        }
        guard let cg = Self.context.createCGImage(out, from: out.extent) else { return nil }
        var full: NSImage?
        if withFull {
            // The crop tool shows the whole photo at the quick size: enough to place a crop on.
            var whole = toned
            let long = max(whole.extent.width, whole.extent.height)
            if long > Double(Self.baseSide) {
                whole = whole.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(Self.baseSide) / long, kCIInputAspectRatioKey: 1])
            }
            if let l = Self.context.createCGImage(whole, from: whole.extent) { full = NSImage(cgImage: l, size: .zero) }
        }
        let k = angle.map { EditPipeline.rotatedScale(pixelSize, degrees: $0) } ?? 1
        let fullSize = CGSize(width: (pixelSize.width * k).rounded(.down), height: (pixelSize.height * k).rounded(.down))
        return Rendered(image: NSImage(cgImage: cg, size: .zero), outputSize: Self.outputSize(pixelSize, recipe: recipe, angle: angle, zoom: zoom ?? 1, rect: rect),
                        warning: warning, crop: crop, full: full, fullSize: fullSize, pixelSize: pixelSize, angle: angle, autoAngle: autoAngle,
                        masks: findMasks ? parts != nil : nil)
    }

    static func outputSize(_ size: CGSize, recipe: EditRecipe, angle: Double? = nil, zoom: Double = 1, rect: CGRect? = nil) -> CGSize {
        var w = size.width, h = size.height
        if let angle { let k = EditPipeline.rotatedScale(size, degrees: angle); w *= k; h *= k }
        if let rect {
            w *= rect.width; h *= rect.height
        } else {
            if let a = recipe.aspect(for: size) { let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio); w = cw; h = ch }
            if zoom > 1 { w /= zoom; h /= zoom }
        }
        if let long = recipe.maxLongSide, Double(long) < max(w, h) {
            let s = Double(long) / max(w, h); w *= s; h *= s
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// The crop tool's shape: the export's, free, the photo's own, or a preset.
enum CropAspect: Hashable {
    case export, free, original, preset(AspectPreset)
    var title: String {
        switch self {
        case .export: "Same as export"
        case .free: "Free"
        case .original: "Original"
        case .preset(let a): a.rawValue
        }
    }
}

/// The big preview of an edit: the selected photo as it will be exported, a film strip to pick another photo, a
/// before/after switch, and the usual editor navigation and tools — zoom (⌘+ ⌘− ⌘0 fit ⌘1 100%, ⌥-scroll, pinch),
/// pan (scroll, Space-drag), a crop tool with handles (C), a level slider and a straighten line.
/// Which part's mask the preview shows (the retouch panel's Show Mask), tinted red; nil is none.
@MainActor
final class MaskOverlay: ObservableObject {
    static let shared = MaskOverlay()
    @Published var part: Retouch.Part? { didSet { if part == nil { brushing = false } } }
    /// Dragging on the preview paints the shown part's mask of that photo (adds to it, or erases).
    @Published var brushing = false { didSet { if brushing { healing = false } } }
    @Published var erase = false
    /// Which mask painting the skin retouch's paints: face skin or body skin (the skin retouch's mask is theirs).
    @Published var skinPaint: Retouch.Part = .faceSkin
    /// The mask a stroke painted with `part` shown goes on.
    func painted(_ part: Retouch.Part) -> Retouch.Part { part == .skin ? skinPaint : part }
    /// The brush's size: its diameter in the photo's own pixels (at full size), as Photoshop's, so a mole on a
    /// 6000-pixel photo gets a brush its size.
    @Published var size = MaskOverlay.stored("maskBrush.px", 150) { didSet { UserDefaults.standard.set(size, forKey: "maskBrush.px") } }
    /// The brush's edge: 0 hard, 1 fading out from the centre.
    @Published var softness = MaskOverlay.stored("maskBrush.softness", 0.5) { didSet { UserDefaults.standard.set(softness, forKey: "maskBrush.softness") } }
    static let sizes: ClosedRange<Double> = 1...2500

    /// Dragging on the preview heals what it covers (the healing brush), on that photo. Needs no masks.
    @Published var healing = false { didSet { if healing { brushing = false } else { healSource = nil } } }
    /// The healing brush's own size and edge (a blemish wants a smaller brush than a mask).
    @Published var healSize = MaskOverlay.stored("healBrush.px", 40) { didSet { UserDefaults.standard.set(healSize, forKey: "healBrush.px") } }
    @Published var healSoftness = MaskOverlay.stored("healBrush.softness", 0.3) { didSet { UserDefaults.standard.set(healSoftness, forKey: "healBrush.softness") } }
    /// Where the healing brush heals from, picked by hand (⌥-click) on one photo: the spot (normalized, in the photo
    /// as shot), and once the first stroke from it is painted, the shift from the strokes to their source (kept for
    /// the next ones, as Photoshop's aligned healing brush). nil: the brush finds clean skin itself.
    @Published var healSource: (photo: String, point: CGPoint, shift: CGVector?)?

    static func stored(_ key: String, _ fallback: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? fallback }

    /// The brush in use: the healing brush's, or the mask brush's.
    var brushSize: Double { healing ? healSize : size }
    var brushSoftness: Double { healing ? healSoftness : softness }

    /// [ and ] make the brush smaller or bigger, in Photoshop's steps: a pixel at a time below 10, then 10, 25, 50
    /// and 100 as it grows.
    func resize(_ by: Int) {
        let next = Self.step(brushSize, up: by > 0)
        if healing { healSize = next } else { size = next }
    }

    static func step(_ px: Double, up: Bool) -> Double {
        // Going down from a step's edge takes the smaller step (100 → 90, not 75).
        let at = up ? px : px - 0.5
        let step: Double = at < 10 ? 1 : at < 100 ? 10 : at < 200 ? 25 : at < 300 ? 50 : 100
        let next = up ? ((px + 0.5) / step).rounded(.down) * step + step : ((px - 0.5) / step).rounded(.up) * step - step
        return min(sizes.upperBound, max(sizes.lowerBound, next))
    }

    /// The brush's radius as a share of a photo's short side (how strokes are kept, whatever the photo's size).
    static func radius(_ px: Double, photo size: CGSize) -> Double { px / 2 / max(1, min(size.width, size.height)) }

    /// Finding a photo's masks is slow, so the preview looks for them only in the photos Find Masks was clicked for
    /// (by path); until then the retouch and the masks' tools wait.
    @Published private(set) var asked: Set<String> = []
    /// What looking came to: true found, false nobody found. Absent while looking.
    @Published private(set) var found: [String: Bool] = [:]

    enum Masks { case notFound, finding, ready, nobody }

    func masks(_ photo: URL?) -> Masks {
        guard let path = photo?.path, asked.contains(path) else { return .notFound }
        return found[path].map { $0 ? .ready : .nobody } ?? .finding
    }

    func find(_ photo: URL) {
        found[photo.path] = nil
        asked.insert(photo.path)
    }

    func landed(_ photo: URL, found ok: Bool) {
        guard asked.contains(photo.path), found[photo.path] != ok else { return }
        found[photo.path] = ok
    }
}

struct EditPreview: View {
    @ObservedObject private var maskOverlay = MaskOverlay.shared
    /// Drawn again with the body-parts model once it's downloaded.
    @ObservedObject private var bodyParts = BodyPartsModel.shared
    @Binding var recipe: EditRecipe
    let samples: [ToolItem]
    var filmstrip = true
    /// Offers each photo its own crop, level and drag-to-place.
    var perPhotoCrop = true
    /// When set, photos can be ticked off: the action then applies only to the ticked ones (this set holds the
    /// unticked ones, so photos added later start ticked).
    var excluded: Binding<Set<ToolItem>>? = nil
    /// A word on some photos (why one was unticked), shown with the file name on hover.
    var notes: [ToolItem: String] = [:]
    /// Reports which photo is shown, for controls elsewhere that edit just that one.
    var shown: Binding<URL?>? = nil
    @State private var index = 0
    @State private var gridMode = false
    /// The strip re-centres for the arrows, not when a visible thumbnail is clicked.
    @State private var clickedInStrip = false
    /// Last photo ticked or unticked, for Shift-click ranges.
    @State private var anchor: Int?
    @State private var rendered: PreviewCache.Rendered?
    @State private var showOriginal = false
    @State private var rendering = false
    @State private var hovering = false
    /// Bumped when a photo's crop is edited or reset, to render again.
    @State private var placements = 0
    /// The current photo's latest export, for the info bar.
    @State private var lastExport: ExportHistory.Record?
    @State private var exports = 0
    /// Arrow keys step through the photos (Space ticks or unticks, Return opens a grid photo large) while the
    /// preview has the keyboard focus, which a click on it or on the strip gives it.
    @FocusState private var focused: Bool
    /// How many thumbnails the grid fits in a row (for ↑ and ↓).
    @State private var gridColumns = 1

    // Navigation, as in any photo editor.
    /// Output pixels per screen pixel; nil fits the photo to the view.
    @State private var zoom: Double?
    @State private var zoomStart: Double?
    @State private var pan = CGSize.zero
    @State private var panStart: CGSize?
    @State private var panned = false
    @State private var spaceDown = false
    @State private var viewSize = CGSize.zero
    @Environment(\.displayScale) private var displayScale

    // The crop tool.
    @State private var cropping = false
    /// The crop being edited (normalized in the levelled photo): the tool's box, a crop dragged under the photo, or
    /// the zoom slider's live crop.
    @State private var box: CGRect?
    @State private var boxStart: CGRect?
    @State private var cropDrag: CropDrag?
    @State private var cropAspect = CropAspect.export
    /// Degrees clockwise the photo is shown turned, live (level slider, rotate drag), until committed.
    @State private var liveAngle: Double?
    @State private var straightening = false
    @State private var line: (CGPoint, CGPoint)?
    /// The crop zoom slider in progress.
    @State private var liveZoom: Double?

    // The mask brush.
    /// Strokes drawn on screen: the one being painted, and those painted but not yet in a render.
    @State private var liveStrokes: [LiveStroke] = []
    /// Where the brush is over the photo, for its outline.
    @State private var brushAt: CGPoint?
    /// The healing brush's ⌥-click (picking where it heals from) in progress.
    @State private var pickingSource = false

    struct LiveStroke {
        var points: [CGPoint]
        var erase: Bool
        /// Points on screen.
        var radius: CGFloat
        var done = false
        var heal = false
    }

    // The zoom tool, as in Photoshop: Z held, a click zooms in, ⌥-click out.
    @State private var zoomKey = false
    /// The key Z is on this keyboard's layout, to check it is still held.
    @State private var zoomKeyCode: UInt16 = 6
    @State private var optionKey = false
    @State private var keyMonitor: Any?

    enum CropDrag { case move, handle(Handle), rotate(Double), line }
    enum Handle: CaseIterable { case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    var current: ToolItem? { samples.isEmpty ? nil : samples[min(index, samples.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            if showGrid { grid } else { previewArea; infoBar }
            if excluded != nil && samples.count > 1 { selectionBar }
            if filmstrip && samples.count > 1 && !showGrid { strip }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1, nudge: CGSize(width: -1, height: 0)) }
        .onKeyPress(.rightArrow) { step(1, nudge: CGSize(width: 1, height: 0)) }
        .onKeyPress(.upArrow) { step(showGrid ? -gridColumns : -1, nudge: CGSize(width: 0, height: -1)) }
        .onKeyPress(.downArrow) { step(showGrid ? gridColumns : 1, nudge: CGSize(width: 0, height: 1)) }
        .onKeyPress(.home) { step(-samples.count) }
        .onKeyPress(.end) { step(samples.count) }
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            // Space held: drag pans (the hand tool). Tapped: ticks or unticks the photo.
            if press.phase == .down { spaceDown = true; panned = false; return .handled }
            spaceDown = false
            guard !panned, excluded != nil, !samples.isEmpty, !cropping else { return .handled }
            tick(min(index, samples.count - 1))
            return .handled
        }
        .onKeyPress(.return) {
            if cropping { applyCrop(); return .handled }
            guard showGrid else { return .ignored }
            gridMode = false
            return .handled
        }
        .onKeyPress(.escape) {
            if brushActive { maskOverlay.brushing = false; maskOverlay.healing = false; return .handled }
            guard cropping else { return .ignored }
            cancelCrop()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "[]")) { press in
            guard brushActive, !press.modifiers.contains(.command) else { return .ignored }
            maskOverlay.resize(press.characters == "]" ? 1 : -1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "cC")) { _ in
            guard canCrop else { return .ignored }
            if cropping { cancelCrop() } else { startCrop() }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // ⌘+ / ⌘− zoom, ⌘0 fit, ⌘1 100%, as in every editor.
            guard press.modifiers.contains(.command), !showGrid else { return .ignored }
            switch press.characters {
            case "=", "+": zoomStep(1)
            case "-", "_": zoomStep(-1)
            case "0": setZoom(nil)
            case "1": setZoom(1)
            default: return .ignored
            }
            return .handled
        }
        .onAppear { if samples.count > 1 { focused = true } }
        .onChange(of: samples.count) { if index >= samples.count { index = 0 } }
        .onChange(of: samples.count > 1) { if samples.count > 1, ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] == "grid" { gridMode = true } }
        .onChange(of: current?.url, initial: true) {
            shown?.wrappedValue = current?.url
            if cropping { cancelCrop() }
            setZoom(nil)
            liveStrokes = []
            maskOverlay.healSource = nil
        }
        .onAppear(perform: watchZoomKey)
        .onDisappear { keyMonitor.map(NSEvent.removeMonitor); keyMonitor = nil; zoomKey = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in zoomKey = false; optionKey = false }
        .task(id: "\(recipe.hashValue)|\(current?.url.path ?? "")|\(showOriginal)|\(placements)|\(renderLongSide)|\(perPhotoCrop)|\(maskOverlay.part?.rawValue ?? "")|\(bodyParts.state == .ready)|\(findsMasks)") { await render() }
        .task(id: "\(current?.url.path ?? "")|\(exports)") {
            guard let url = current?.url else { lastExport = nil; return }
            lastExport = await Task.detached { ExportHistory.shared.exports(of: url).first }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: CropPlacements.changed)) { _ in placements += 1 }
        .onReceive(NotificationCenter.default.publisher(for: ExportHistory.changed)) { _ in exports += 1 }
    }

    /// Moves to another photo with the keyboard (no wrapping at the ends); the strip or grid scrolls to it. In the
    /// crop tool, the arrows nudge the crop instead.
    func step(_ by: Int, nudge: CGSize? = nil) -> KeyPress.Result {
        if cropping, let nudge, let b = box {
            box = clamp(b.offsetBy(dx: nudge.width * 0.005, dy: nudge.height * 0.005))
            return .handled
        }
        guard samples.count > 1 else { return .ignored }
        let i = min(max(min(index, samples.count - 1) + by, 0), samples.count - 1)
        if i != index { index = i }
        return .handled
    }

    // MARK: - Navigation

    /// Points per output pixel when the photo fits the view.
    func fitScale(_ out: CGSize, in size: CGSize) -> CGFloat {
        guard out.width > 0, out.height > 0 else { return 1 }
        return min((size.width - 36) / out.width, (size.height - 36) / out.height)
    }

    /// Points per output pixel as shown now.
    func scale(_ out: CGSize, in size: CGSize) -> CGFloat { zoom.map { CGFloat($0) / displayScale } ?? fitScale(out, in: size) }

    /// Output pixels per screen pixel as shown now (100% = 1).
    var effectiveZoom: Double {
        guard let out = rendered?.outputSize else { return 1 }
        return zoom ?? Double(fitScale(out, in: viewSize) * displayScale)
    }

    /// Screen pixels the photo's long side gets, so it is rendered at that resolution (in steps, so a window resize
    /// doesn't render at every pixel). Capped: beyond that the screen upscales the last render.
    var renderLongSide: Int {
        guard let out = rendered?.outputSize ?? current.flatMap({ PreviewCache.shared.entry($0.url)?.pixelSize }), viewSize.width > 0 else { return PreviewCache.baseSide }
        let px = Double(max(out.width, out.height) * scale(out, in: viewSize) * displayScale)
        let stepped = Int((px / 256).rounded(.up)) * 256
        return min(max(stepped, 512), 4096)
    }

    static let zoomLevels: [Double] = [0.125, 0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 6, 8]

    func zoomStep(_ direction: Int) {
        let z = effectiveZoom
        let next = direction > 0 ? Self.zoomLevels.first { $0 > z * 1.02 } : Self.zoomLevels.last { $0 < z / 1.02 }
        setZoom(next ?? (direction > 0 ? Self.zoomLevels.last : Self.zoomLevels.first))
    }

    func setZoom(_ z: Double?) {
        zoom = z
        pan = .zero
    }

    /// Zooms about a point of the view, so what is under the cursor stays there.
    func zoomAround(_ p: CGPoint, factor: Double) {
        let old = effectiveZoom
        let new = min(max(old * factor, 0.05), 16)
        let k = new / old
        let vc = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        pan = CGSize(width: (p.x - vc.x) * (1 - k) + pan.width * k, height: (p.y - vc.y) * (1 - k) + pan.height * k)
        zoom = new
        pan = clampedPan(pan)
    }

    /// The zoom tool's click: a step in (or out, to the photo fitting at most) about the point clicked.
    func zoomClick(at p: CGPoint, out: Bool) {
        guard let r = rendered, !showGrid, !cropping else { return }
        let z = effectiveZoom
        if out {
            let fit = Double(fitScale(r.outputSize, in: viewSize) * displayScale)
            guard let next = Self.zoomLevels.last(where: { $0 < z / 1.02 }), next > fit * 1.02 else { setZoom(nil); return }
            zoomAround(p, factor: next / z)
        } else if let next = Self.zoomLevels.first(where: { $0 > z * 1.02 }) {
            zoomAround(p, factor: next / z)
        }
    }

    /// Z held is the zoom tool (watched over the whole window while the preview is shown, but not while typing
    /// in a field; ⌘Z stays undo).
    func watchZoomKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            if e.type == .flagsChanged { optionKey = e.modifierFlags.contains(.option); return e }
            guard e.charactersIgnoringModifiers?.lowercased() == "z" else { return e }
            // Z let go ends the zoom tool whatever else is held (Z, then ⌘Z to undo, would otherwise leave it on).
            if e.type == .keyUp {
                let was = zoomKey
                zoomKey = false
                return was ? nil : e
            }
            guard e.modifierFlags.isDisjoint(with: [.command, .control]), !(e.window?.firstResponder is NSText) else { return e }
            zoomKey = true
            zoomKeyCode = e.keyCode
            optionKey = e.modifierFlags.contains(.option)
            return nil
        }
    }

    /// Z held (the zoom tool), checked against the keyboard: a key-up missed would leave every drag a zoom click, and
    /// the brushes painting nothing.
    func zoomToolOn() -> Bool {
        if zoomKey && !CGEventSource.keyState(.combinedSessionState, key: zoomKeyCode) { zoomKey = false }
        return zoomKey
    }

    /// The photo never leaves the view: centred where it fits, and never dragged past its edge where it doesn't.
    func clampedPan(_ p: CGSize) -> CGSize {
        guard let out = rendered?.outputSize else { return .zero }
        let s = scale(out, in: viewSize), w = out.width * s, h = out.height * s
        let mx = max(0, (w - viewSize.width) / 2 + 18), my = max(0, (h - viewSize.height) / 2 + 18)
        return CGSize(width: min(max(p.width, -mx), mx), height: min(max(p.height, -my), my))
    }

    /// The photo is bigger than the view, so dragging pans it.
    var canPan: Bool {
        guard let out = rendered?.outputSize else { return false }
        let s = scale(out, in: viewSize)
        return out.width * s > viewSize.width || out.height * s > viewSize.height
    }

    // MARK: - Preview

    var previewArea: some View {
        GeometryReader { g in
            ZStack {
                Color(nsColor: NSColor(white: 0.13, alpha: 1))
                if let r = rendered {
                    if (cropping || box != nil) && !showOriginal, let full = r.full {
                        cropLayer(r, full: full, in: g.size)
                    } else {
                        photoLayer(r, in: g.size)
                    }
                } else if samples.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                        Text("Add photos or people to preview the edit").font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                }
                // In the middle of the preview, on a dark disc so it shows over a bright photo as well as the
                // background; it doesn't take clicks, so the photo can still be panned or placed meanwhile.
                if rendering {
                    ProgressView().controlSize(.regular).tint(.white)
                        .padding(14)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onChange(of: g.size, initial: true) { viewSize = g.size; pan = clampedPan(pan) }
        }
        .background(EventCatcher(onScroll: scrolled, onMagnify: magnified))
        .overlay(alignment: .top) {
            // The photo's own tools on the left, the before/after switch on the right; in a narrow preview the
            // switch drops to a second row instead of covering the tools.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) { tools; Spacer(minLength: 8); compareSwitch }
                VStack(alignment: .trailing, spacing: 0) { HStack(spacing: 0) { tools; Spacer(minLength: 0) }; compareSwitch }
            }
        }
        .clipped()
        .environment(\.colorScheme, .dark)
        .simultaneousGesture(TapGesture().onEnded { focused = true })
    }

    /// The edited photo at the view's zoom, dragged where it was panned.
    func photoLayer(_ r: PreviewCache.Rendered, in size: CGSize) -> some View {
        let out = r.outputSize, s = scale(out, in: size)
        let w = out.width * s, h = out.height * s
        // The level slider shows its turn live: the photo turned the rest of the way, and zoomed in just enough to
        // hide the corners, until the real render lands.
        let delta = liveAngle.map { $0 + (r.angle ?? 0) } ?? 0
        let grow = delta == 0 ? 1 : 1 / EditPipeline.rotatedScale(out, degrees: delta)
        return ZStack {
            // An overlay, so a photo zoomed in past the view doesn't grow the stack: the layers over it (the brushes,
            // the watermark's click) take their points as the view's (in a bigger stack, a stroke landed off the photo).
            Color.clear.overlay {
                Image(nsImage: r.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)
                    .rotationEffect(.degrees(delta))
                    .scaleEffect(grow)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .overlay { if hovering && clickPlacesWatermark && !spaceDown { thirds } }
                    .offset(pan)
            }
            Color.clear.contentShape(Rectangle())
                .gesture(panOrPlaceGesture(r, in: size).simultaneously(with: viewZoomGesture))
                .simultaneousGesture(TapGesture(count: 2).onEnded { if !zoomToolOn() { setZoom(zoom == nil ? 1 : nil) } })
                .simultaneousGesture(SpatialTapGesture().onEnded { v in
                    if zoomToolOn() { zoomClick(at: v.location, out: optionKey); return }
                    placeWatermark(at: v.location, photo: CGRect(x: (size.width - w) / 2 + pan.width, y: (size.height - h) / 2 + pan.height, width: w, height: h))
                })
            if brushActive { brushLayer(r, photo: CGRect(x: (size.width - w) / 2 + pan.width, y: (size.height - h) / 2 + pan.height, width: w, height: h)) }
        }
        .frame(width: size.width, height: size.height)
        .pointerStyle(zoomKey && !cropping ? (optionKey ? .zoomOut : .zoomIn) : nil)
        .onHover { hovering = $0 }
        .help(help)
    }

    /// A tap puts a logo or text watermark in that ninth of the photo (banners stay on their edge).
    var clickPlacesWatermark: Bool { recipe.watermark.map { !$0.isBanner } ?? false }

    func placeWatermark(at p: CGPoint, photo: CGRect) {
        guard clickPlacesWatermark, !showOriginal, photo.contains(p), !panned else { return }
        let col = min(2, max(0, Int((p.x - photo.minX) / (photo.width / 3)))), row = min(2, max(0, Int((p.y - photo.minY) / (photo.height / 3))))
        recipe.watermark?.position = WatermarkSpec.Position.allCases[row * 3 + col]
    }

    var thirds: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .allowsHitTesting(false)
    }

    /// Dragging pans a zoomed-in photo (or any photo while Space is held); at fit size with a crop, it moves the
    /// photo under the crop, as in the crop tool.
    func panOrPlaceGesture(_ r: PreviewCache.Rendered, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                panned = true
                if canPan || spaceDown {
                    if panStart == nil { panStart = pan }
                    pan = clampedPan(CGSize(width: panStart!.width + v.translation.width, height: panStart!.height + v.translation.height))
                } else if canCrop, let c = r.crop {
                    // The crop fills the view; the photo moves under it, so the crop moves the other way.
                    let s = scale(r.outputSize, in: size)
                    box = clamp(CGRect(x: c.minX - v.translation.width * c.width / (r.outputSize.width * s),
                                       y: c.minY - v.translation.height * c.height / (r.outputSize.height * s), width: c.width, height: c.height))
                }
            }
            .onEnded { _ in
                panStart = nil
                if !cropping, let b = box, let url = current?.url {
                    // Stays on screen until the new crop is rendered.
                    CropPlacements.shared.set(CGPoint(x: b.midX, y: b.midY), for: url)
                }
                DispatchQueue.main.async { panned = false }
            }
    }

    var viewZoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { v in
                if zoomStart == nil { zoomStart = effectiveZoom }
                zoomAround(v.startLocation, factor: Double(v.magnification) * zoomStart! / effectiveZoom)
            }
            .onEnded { _ in zoomStart = nil }
    }

    func scrolled(_ p: CGPoint, _ delta: CGSize, _ mods: NSEvent.ModifierFlags) {
        guard rendered != nil, !showGrid else { return }
        if mods.contains(.option) || mods.contains(.control) {
            zoomAround(p, factor: exp(Double(delta.height) * 0.01))
        } else if !cropping, canPan {
            pan = clampedPan(CGSize(width: pan.width + delta.width, height: pan.height + delta.height))
        }
    }

    func magnified(_ p: CGPoint, _ m: CGFloat) {
        guard rendered != nil, !showGrid, !cropping else { return }
        zoomAround(p, factor: 1 + Double(m))
    }

    var help: String {
        let zoomTool = "Z-click zooms in, ⌥Z-click out"
        if brushActive && maskOverlay.healing {
            return "Drag over a blemish to heal it from clean skin nearby; ⌥-click to pick where it heals from instead. [ and ] change the brush size, \(zoomTool), Space-drag pans, Esc stops healing"
        }
        if brushActive { return "Drag to paint the mask (⌥-drag does the opposite), [ and ] change the brush size, \(zoomTool), Space-drag pans, Esc stops painting" }
        var parts = ["Scroll or Space-drag to pan, ⌥-scroll or pinch to zoom, double-click for 100%, \(zoomTool)"]
        if canCrop { parts.append(rendered?.crop == nil ? "C for the crop tool" : "drag the photo to move its crop, C for the crop tool") }
        if clickPlacesWatermark { parts.append("click where the watermark should go") }
        return parts.joined(separator: "; ")
    }

    // MARK: - Mask brush and healing brush

    /// Dragging paints the shown part's mask of this photo (the retouch panel's Paint mask), or heals it (the
    /// healing brush, which needs no masks).
    var brushActive: Bool {
        guard perPhotoCrop && !showOriginal && !cropping && box == nil && current != nil && !showGrid else { return false }
        if maskOverlay.healing { return true }
        return maskOverlay.brushing && maskOverlay.part != nil && maskOverlay.masks(current?.url) == .ready
    }

    /// The brush's radius on screen: its pixels of the photo at full size, at the zoom shown (`photo` is where the
    /// output sits in the view; the output is the crop of the levelled photo).
    func brushRadius(_ r: PreviewCache.Rendered, photo: CGRect) -> CGFloat {
        guard r.fullSize.width > 0 else { return 10 }
        let pointsPerPixel = photo.width / ((r.crop?.width ?? 1) * r.fullSize.width)
        return max(1, CGFloat(maskOverlay.brushSize / 2) * pointsPerPixel)
    }

    /// The strokes being painted, the brush's outline under the cursor, and where the healing brush heals from when
    /// that was picked.
    func brushLayer(_ r: PreviewCache.Rendered, photo: CGRect) -> some View {
        let radius = brushRadius(r, photo: photo)
        let softness = maskOverlay.brushSoftness
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(brushGesture(r, photo: photo, radius: radius))
                .onContinuousHover { phase in
                    if case .active(let p) = phase { brushAt = p } else { brushAt = nil }
                }
            ForEach(liveStrokes.indices, id: \.self) { i in
                let st = liveStrokes[i]
                let colour = st.heal ? Color.black.opacity(0.35) : st.erase ? Color.black.opacity(0.5) : Color.red.opacity(0.55)
                if st.points.count == 1 {
                    Circle().fill(colour).frame(width: st.radius * 2, height: st.radius * 2).position(st.points[0])
                } else {
                    Path { $0.addLines(st.points) }
                        .stroke(colour, style: StrokeStyle(lineWidth: st.radius * 2, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            if let p = sourceMark(r, photo: photo) {
                ZStack {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.black.opacity(0.6)).offset(x: 1, y: 1)
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Circle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: radius * 2, height: radius * 2)
                }
                .position(p)
                .allowsHitTesting(false)
            }
            if let p = brushAt, !spaceDown, !zoomKey {
                ZStack {
                    Circle().stroke(.black.opacity(0.6), lineWidth: 3)
                    Circle().stroke(.white, lineWidth: 1)
                    if softness > 0.05 {
                        // Where the edge fades: inside the brush for a mask, past it for healing (all it covers is healed).
                        Circle().stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .padding(maskOverlay.healing ? -radius * CGFloat(Healing.fade(softness) - 1) : radius * CGFloat(min(1, softness)))
                    }
                }
                .frame(width: radius * 2, height: radius * 2)
                .position(p)
                .allowsHitTesting(false)
            }
        }
    }

    /// Drags paint (⌥ the other way from the panel's + / −) or heal (⌥-click picks where from); with Space held
    /// they pan, with Z held a click zooms.
    func brushGesture(_ r: PreviewCache.Rendered, photo: CGRect, radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                brushAt = v.location
                if spaceDown || panStart != nil {
                    panned = true
                    if panStart == nil { panStart = pan }
                    pan = clampedPan(CGSize(width: panStart!.width + v.translation.width, height: panStart!.height + v.translation.height))
                    return
                }
                if let last = liveStrokes.last, !last.done {
                    // A point every few pixels is plenty.
                    if hypot(v.location.x - last.points.last!.x, v.location.y - last.points.last!.y) >= max(1, radius * 0.15) {
                        liveStrokes[liveStrokes.count - 1].points.append(v.location)
                    }
                } else if zoomToolOn() || pickingSource {
                    return
                } else if maskOverlay.healing && NSEvent.modifierFlags.contains(.option) {
                    pickingSource = true
                } else {
                    let erase = !maskOverlay.healing && maskOverlay.erase != NSEvent.modifierFlags.contains(.option)
                    liveStrokes.append(LiveStroke(points: [v.location], erase: erase, radius: radius, heal: maskOverlay.healing))
                }
            }
            .onEnded { v in
                if panStart != nil { panStart = nil; DispatchQueue.main.async { panned = false }; return }
                if pickingSource {
                    pickingSource = false
                    if let url = current?.url, let p = asShot(v.location, r, photo: photo) {
                        maskOverlay.healSource = (url.path, p, nil)
                    }
                    return
                }
                guard let i = liveStrokes.indices.last, !liveStrokes[i].done else {
                    if zoomToolOn() { zoomClick(at: v.location, out: optionKey) }
                    return
                }
                liveStrokes[i].done = true
                commit(liveStrokes[i], r, photo: photo)
            }
    }

    /// A point of the view in the photo as shot (normalized): the output → the levelled photo → the photo as shot.
    func asShot(_ v: CGPoint, _ r: PreviewCache.Rendered, photo: CGRect) -> CGPoint? {
        guard let url = current?.url, photo.width > 0, photo.height > 0 else { return nil }
        let crop = r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let o = CGPoint(x: (v.x - photo.minX) / photo.width, y: (v.y - photo.minY) / photo.height)
        let q = CGPoint(x: crop.minX + o.x * crop.width, y: crop.minY + o.y * crop.height)
        return MaskBrush.unplace(q, look: CropPlacements.shared.recipe(recipe, for: url).look, levelled: r.angle, size: r.pixelSize)
    }

    /// And back: a point of the photo as shot in the view.
    func inView(_ p: CGPoint, _ r: PreviewCache.Rendered, photo: CGRect) -> CGPoint? {
        guard let url = current?.url else { return nil }
        let crop = r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let q = MaskBrush.place(p, look: CropPlacements.shared.recipe(recipe, for: url).look, levelled: r.angle, size: r.pixelSize)
        return CGPoint(x: photo.minX + (q.x - crop.minX) / crop.width * photo.width, y: photo.minY + (q.y - crop.minY) / crop.height * photo.height)
    }

    /// Where the healing brush heals from, when picked: the spot picked, then (once strokes follow it) as far from the
    /// brush as the first stroke was from the spot.
    func sourceMark(_ r: PreviewCache.Rendered, photo: CGRect) -> CGPoint? {
        guard maskOverlay.healing, let s = maskOverlay.healSource, s.photo == current?.url.path else { return nil }
        guard let shift = s.shift else { return inView(s.point, r, photo: photo) }
        guard let at = liveStrokes.last(where: { !$0.done })?.points.last ?? brushAt, let p = asShot(at, r, photo: photo) else { return nil }
        return inView(CGPoint(x: p.x + shift.dx, y: p.y + shift.dy), r, photo: photo)
    }

    /// Saves a stroke painted on screen with the photo's own edits, in the photo as shot.
    func commit(_ stroke: LiveStroke, _ r: PreviewCache.Rendered, photo: CGRect) {
        guard let url = current?.url else { return }
        let points = stroke.points.compactMap { asShot($0, r, photo: photo) }
        guard !points.isEmpty else { return }
        if stroke.heal {
            // From the spot picked: the first stroke sets how far from it the strokes heal from (aligned).
            var source: CGVector?
            if let s = maskOverlay.healSource, s.photo == url.path {
                source = s.shift ?? CGVector(dx: s.point.x - points[0].x, dy: s.point.y - points[0].y)
                maskOverlay.healSource?.shift = source
            }
            CropPlacements.shared.add(heal: HealStroke(points: points, radius: MaskOverlay.radius(maskOverlay.healSize, photo: r.pixelSize),
                                                       softness: maskOverlay.healSoftness, source: source),
                                      for: url)
            return
        }
        guard let part = maskOverlay.part.map(maskOverlay.painted) else { return }
        CropPlacements.shared.add(MaskStroke(points: points, radius: MaskOverlay.radius(maskOverlay.size, photo: r.pixelSize), softness: maskOverlay.softness,
                                             erase: stroke.erase),
                                  to: part, for: url)
    }

    // MARK: - Crop tool

    var canCrop: Bool { perPhotoCrop && !showOriginal && current != nil && rendered?.full != nil }

    /// Where the photo sits in the view (points) when the crop tool shows all of it.
    func fullFrame(_ r: PreviewCache.Rendered, in size: CGSize) -> CGRect {
        let s = fitScale(r.fullSize, in: size)
        let w = r.fullSize.width * s, h = r.fullSize.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func points(_ n: CGRect, in f: CGRect) -> CGRect {
        CGRect(x: f.minX + n.minX * f.width, y: f.minY + n.minY * f.height, width: n.width * f.width, height: n.height * f.height)
    }

    /// The whole photo with the crop over it: bright inside, dimmed outside, handles to resize, thirds to compose
    /// by. Drag inside to move the crop, a handle to resize it, outside to turn the photo; draw a line along
    /// something that should be level with the straighten tool.
    func cropLayer(_ r: PreviewCache.Rendered, full: NSImage, in size: CGSize) -> some View {
        let f = fullFrame(r, in: size)
        let b = points(box ?? r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1), in: f)
        let delta = liveAngle.map { $0 + (r.angle ?? 0) } ?? 0
        let grow = delta == 0 ? 1 : 1 / EditPipeline.rotatedScale(r.fullSize, degrees: delta)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: full).resizable().interpolation(.high)
                .frame(width: f.width, height: f.height)
                .rotationEffect(.degrees(delta))
                .scaleEffect(grow)
                .position(x: f.midX, y: f.midY)
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(b) }
                .fill(.black.opacity(cropping ? 0.6 : 0.5), style: FillStyle(eoFill: true))
            Path { p in
                for i in 1...2 {
                    p.move(to: CGPoint(x: b.minX + b.width * CGFloat(i) / 3, y: b.minY)); p.addLine(to: CGPoint(x: b.minX + b.width * CGFloat(i) / 3, y: b.maxY))
                    p.move(to: CGPoint(x: b.minX, y: b.minY + b.height * CGFloat(i) / 3)); p.addLine(to: CGPoint(x: b.maxX, y: b.minY + b.height * CGFloat(i) / 3))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 1)
            Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1).frame(width: b.width, height: b.height).offset(x: b.minX, y: b.minY)
            if cropping {
                ForEach(Handle.allCases, id: \.self) { h in
                    let c = handleCenter(h, b)
                    Rectangle().fill(.white).frame(width: 9, height: 9)
                        .overlay(Rectangle().stroke(.black.opacity(0.6), lineWidth: 1))
                        .position(c)
                }
            }
            if let l = line {
                Path { p in p.move(to: l.0); p.addLine(to: l.1) }
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            Color.clear.contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .gesture(cropGesture(r, frame: f))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .help(straightening ? "Drag a line along something that should be level" : "Drag inside to move the crop, a handle to resize it, outside to turn the photo. ⏎ applies, Esc cancels")
    }

    func handleCenter(_ h: Handle, _ b: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: b.minX, y: b.minY)
        case .top: CGPoint(x: b.midX, y: b.minY)
        case .topRight: CGPoint(x: b.maxX, y: b.minY)
        case .left: CGPoint(x: b.minX, y: b.midY)
        case .right: CGPoint(x: b.maxX, y: b.midY)
        case .bottomLeft: CGPoint(x: b.minX, y: b.maxY)
        case .bottom: CGPoint(x: b.midX, y: b.maxY)
        case .bottomRight: CGPoint(x: b.maxX, y: b.maxY)
        }
    }

    func cropGesture(_ r: PreviewCache.Rendered, frame f: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard cropping else { return }
                let b = points(box ?? r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1), in: f)
                if cropDrag == nil {
                    boxStart = box ?? r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    if straightening { cropDrag = .line }
                    else if let h = Handle.allCases.first(where: { hypot(handleCenter($0, b).x - v.startLocation.x, handleCenter($0, b).y - v.startLocation.y) < 11 }) { cropDrag = .handle(h) }
                    else if b.insetBy(dx: -4, dy: -4).contains(v.startLocation) { cropDrag = .move }
                    else { cropDrag = .rotate(angle(from: CGPoint(x: b.midX, y: b.midY), to: v.startLocation)) }
                }
                guard let start = boxStart, let mode = cropDrag else { return }
                let t = CGSize(width: v.translation.width / f.width, height: v.translation.height / f.height)
                switch mode {
                case .line: line = (v.startLocation, v.location)
                case .move: box = clamp(start.offsetBy(dx: t.width, dy: t.height))
                case .handle(let h): box = resized(start, handle: h, by: t, fullSize: r.fullSize)
                case .rotate(let a0):
                    let a = angle(from: CGPoint(x: b.midX, y: b.midY), to: v.location)
                    liveAngle = min(max(-(r.angle ?? 0) + (a - a0), -45), 45)
                }
            }
            .onEnded { v in
                guard let mode = cropDrag else { return }
                cropDrag = nil
                switch mode {
                case .line:
                    line = nil
                    straightening = false
                    guard let url = current?.url, abs(v.translation.width) + abs(v.translation.height) > 8 else { return }
                    // The line's tilt from level (or from upright, when it is nearer vertical), clockwise; turning the
                    // photo back by it levels the line.
                    var tilt = atan2(v.translation.height, v.translation.width) * 180 / .pi
                    if tilt > 45 { tilt -= 90 } else if tilt < -45 { tilt += 90 }
                    let clockwise = -(r.angle ?? 0) - tilt
                    CropPlacements.shared.set(rotation: -(min(max(clockwise, -45), 45) * 10).rounded() / 10, for: url)
                case .rotate:
                    if let a = liveAngle, let url = current?.url { CropPlacements.shared.set(rotation: -(a * 10).rounded() / 10, for: url) }
                    liveAngle = nil
                default: break
                }
            }
    }

    func angle(from c: CGPoint, to p: CGPoint) -> Double { atan2(p.y - c.y, p.x - c.x) * 180 / .pi }

    /// The box kept inside the photo.
    func clamp(_ b: CGRect) -> CGRect {
        var r = b
        r.size.width = min(max(r.width, 0.04), 1)
        r.size.height = min(max(r.height, 0.04), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// Width / height (normalized) the crop tool's shape has on this photo; nil for free.
    func lockedRatio(_ fullSize: CGSize) -> Double? {
        let photo = fullSize.width / fullSize.height
        let px: Double?
        switch cropAspect {
        case .free: px = nil
        case .original: px = photo
        case .preset(let a): px = a.ratio
        case .export: px = recipe.aspect(for: fullSize)?.ratio ?? photo
        }
        return px.map { $0 / photo }
    }

    /// The box with one handle dragged: the opposite side or corner stays; with a locked shape, the height follows
    /// the width (or the other way round for the top and bottom handles).
    func resized(_ start: CGRect, handle h: Handle, by t: CGSize, fullSize: CGSize) -> CGRect {
        var r = start
        let lock = lockedRatio(fullSize)
        func setWidth(_ w: CGFloat, fromLeft: Bool) {
            let nw = max(0.04, w)
            if fromLeft { r.origin.x = r.maxX - nw }
            r.size.width = nw
        }
        func setHeight(_ hh: CGFloat, fromTop: Bool) {
            let nh = max(0.04, hh)
            if fromTop { r.origin.y = r.maxY - nh }
            r.size.height = nh
        }
        switch h {
        case .left, .topLeft, .bottomLeft: setWidth(start.width - t.width, fromLeft: true)
        case .right, .topRight, .bottomRight: setWidth(start.width + t.width, fromLeft: false)
        default: break
        }
        switch h {
        case .top, .topLeft, .topRight: setHeight(start.height - t.height, fromTop: true)
        case .bottom, .bottomLeft, .bottomRight: setHeight(start.height + t.height, fromTop: false)
        default: break
        }
        if let lock {
            switch h {
            case .top, .bottom:
                let nw = r.height * lock
                r.origin.x = start.midX - nw / 2
                r.size.width = nw
            case .left, .right:
                let nh = r.width / lock
                r.origin.y = start.midY - nh / 2
                r.size.height = nh
            default:
                // Corners follow the width.
                let nh = r.width / lock
                if h == .topLeft || h == .topRight { r.origin.y = start.maxY - nh }
                r.size.height = nh
            }
        }
        // Still inside the photo: a locked shape shrinks to fit instead of sliding.
        if r.minX < 0 || r.minY < 0 || r.maxX > 1 || r.maxY > 1 {
            if lock != nil {
                r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let nw = min(r.width, r.height * lock!), nh = nw / lock!
                r = CGRect(x: h == .left || h == .topLeft || h == .bottomLeft ? r.maxX - nw : r.minX,
                           y: h == .top || h == .topLeft || h == .topRight ? r.maxY - nh : r.minY, width: nw, height: nh)
            } else {
                r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        return clamp(r)
    }

    func startCrop() {
        guard canCrop, let r = rendered, let url = current?.url else { return }
        let e = CropPlacements.shared.edit(for: url)
        if e?.rect != nil { cropAspect = .free }
        else if let s = e?.shape { cropAspect = s.aspect.map { .preset($0) } ?? .original }
        else { cropAspect = .export }
        box = r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        cropping = true
        setZoom(nil)
        focused = true
    }

    func cancelCrop() {
        cropping = false
        box = nil
        liveAngle = nil
        line = nil
        straightening = false
        cropDrag = nil
    }

    /// Saves the box as this photo's crop: drawn free, it is kept as drawn; in a shape, as that shape's crop zoomed
    /// and placed, so the export (and every other screen) makes the same one.
    func applyCrop() {
        guard let b = box, let r = rendered, let url = current?.url else { cancelCrop(); return }
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch cropAspect {
        case .free:
            CropPlacements.shared.set(rect: b == whole ? nil : b, for: url)
        case .export, .original, .preset:
            let shape: CropShape? = switch cropAspect {
            case .original: .original
            case .preset(let a): .preset(a)
            default: nil
            }
            CropPlacements.shared.set(shape: shape, for: url)
            let photo = r.fullSize.width / r.fullSize.height
            let ratio = (lockedRatio(r.fullSize) ?? 1) * photo
            // The largest crop of that shape, normalized: zoom is how much smaller the box is.
            let w0 = min(1, ratio / photo)
            let zoom = w0 / max(b.width, 0.0001)
            CropPlacements.shared.set(zoom: zoom, center: CGPoint(x: b.midX, y: b.midY), for: url)
        }
        cancelCrop()
    }

    /// The box reshaped to the tool's shape, about its centre, as large as the old one allows.
    func reshapeBox(_ r: PreviewCache.Rendered) {
        guard let b = box else { return }
        guard let lock = lockedRatio(r.fullSize) else { return }
        var w = b.width, h = w / lock
        if h > b.height { h = b.height; w = h * lock }
        box = clamp(CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h))
    }

    // MARK: - Tools

    @ViewBuilder
    var tools: some View {
        if cropping, let r = rendered {
            cropToolbar(r)
        } else if canCrop, let current, let r = rendered {
            HStack(spacing: 0) {
                cropMenu(current, r)
                ZoomButton(url: current.url, live: $liveZoom, onLive: { showLiveZoom($0, r) })
                LevelButton(url: current.url, rendered: r, straighten: recipe.straighten == true, live: $liveAngle)
            }
        }
    }

    /// The zoom slider's crop, live: the shaped crop zoomed about its centre, until the slider is let go.
    func showLiveZoom(_ z: Double?, _ r: PreviewCache.Rendered) {
        guard let z, let c = r.crop ?? Optional(CGRect(x: 0, y: 0, width: 1, height: 1)), let url = current?.url else { box = nil; return }
        let now = CropPlacements.shared.zoom(for: url) ?? 1
        let s = now / z
        box = clamp(CGRect(x: c.midX - c.width * s / 2, y: c.midY - c.height * s / 2, width: c.width * s, height: c.height * s))
    }

    func cropToolbar(_ r: PreviewCache.Rendered) -> some View {
        HStack(spacing: 6) {
            Menu {
                Picker("", selection: Binding(get: { cropAspect }, set: { cropAspect = $0; reshapeBox(r) })) {
                    Text("Free").tag(CropAspect.free)
                    Text("Same as export (\(recipe.aspect(for: r.fullSize)?.rawValue ?? "Original"))").tag(CropAspect.export)
                    Divider()
                    Text("Original").tag(CropAspect.original)
                    ForEach(AspectPreset.allCases) { a in Text(a.label).tag(CropAspect.preset(a)) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Label(cropAspect.title, systemImage: "aspectratio").foregroundStyle(.white.opacity(0.85))
            }
            .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            .help("The crop's shape")
            Button { straightening.toggle() } label: { Label("Straighten", systemImage: "level") }
                .buttonStyle(.borderless)
                .foregroundStyle(straightening ? Color.accent : .white.opacity(0.85))
                .help("Then drag a line along something that should be level (a horizon, a floor, a pillar)")
            Button("Reset") {
                if let url = current?.url { CropPlacements.shared.resetPlacement(for: url); CropPlacements.shared.set(shape: nil, for: url) }
                cancelCrop()
            }
            .buttonStyle(.borderless)
            .help("Back to the automatic crop, which keeps the people in frame")
            Divider().frame(height: 14)
            Button("Cancel") { cancelCrop() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            Button("Apply") { applyCrop() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
    }

    var compareSwitch: some View {
        Picker("", selection: $showOriginal) {
            Text("Edited").tag(false)
            Text("Original").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().padding(10)
        .help("Compare with the original photo")
        .onChange(of: showOriginal) { if showOriginal && cropping { cancelCrop() } }
    }

    /// Opens the crop tool; the menu picks this photo's crop shape without it.
    func cropMenu(_ item: ToolItem, _ r: PreviewCache.Rendered) -> some View {
        let own = CropPlacements.shared.shape(for: item.url)
        let free = CropPlacements.shared.rect(for: item.url) != nil
        let shared = recipe.aspect(for: r.pixelSize)?.rawValue ?? "Original"
        return Menu {
            Button("Crop & Straighten…    C") { startCrop() }
            Divider()
            Picker("", selection: Binding(get: { own }, set: { CropPlacements.shared.set(shape: $0, for: item.url); CropPlacements.shared.set(rect: nil, for: item.url) })) {
                Text("Same as the others (\(shared))").tag(CropShape?.none)
                Divider()
                Text("Original").tag(CropShape?.some(.original))
                ForEach(AspectPreset.allCases) { a in Text(a.label).tag(CropShape?.some(.preset(a))) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(free ? "Crop: Free" : own.map { "This photo: \($0.label)" } ?? "Crop: \(shared)", systemImage: "crop")
        } primaryAction: {
            startCrop()
        }
        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
        .font(.caption)
        .foregroundStyle(own == nil && !free ? .white.opacity(0.85) : Color.accent)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .help("Crop this photo (C): handles to resize, drag to move, drag outside to turn. The menu picks its shape.")
    }

    /// The photo's name, size, zoom and export state, in a strip of its own under the preview: never over the photo,
    /// where it hid the bottom of the picture and a watermark placed there.
    var infoBar: some View {
        HStack(spacing: 10) {
            if samples.count > 1 {
                Button { index = (index - 1 + samples.count) % samples.count } label: { Image(systemName: "chevron.left") }
                Text("\(min(index, samples.count - 1) + 1) of \(samples.count)").monospacedDigit()
                Button { index = (index + 1) % samples.count } label: { Image(systemName: "chevron.right") }
            }
            if let current { Text(current.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
            if let s = rendered?.outputSize, !showOriginal { Text("→ \(Int(s.width)) × \(Int(s.height)) px \(recipe.outputFormat.label)").monospacedDigit() }
            if rendered != nil && !cropping { zoomMenu }
            if let w = rendered?.warning { Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            if let current, !showOriginal, !cropping, let e = CropPlacements.shared.edit(for: current.url), e.cropEdited {
                Button { CropPlacements.shared.resetPlacement(for: current.url) } label: { Label("Reset crop", systemImage: "arrow.uturn.backward") }
                    .help("This crop was \(e.rect != nil ? "drawn" : e.zoom != nil ? "zoomed and placed" : "placed") by hand: go back to the automatic one, which keeps the people in frame")
            }
            if let e = lastExport {
                Label("Exported \(e.date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Latest export: \(e.path)")
            }
            Spacer(minLength: 8)
            if let current { CopyPathButton(path: current.url.path, what: "photo") }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
        .environment(\.colorScheme, .dark)
        .opacity(samples.isEmpty ? 0 : 1)
    }

    /// "Fit" or the zoom as a percentage, with the usual steps.
    var zoomMenu: some View {
        Menu {
            Button("Fit    ⌘0") { setZoom(nil) }
            ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { z in
                Button("\(Int(z * 100))%" + (z == 1 ? "    ⌘1" : "")) { setZoom(z) }
            }
            Divider()
            Button("Zoom In    ⌘+") { zoomStep(1) }
            Button("Zoom Out    ⌘−") { zoomStep(-1) }
        } label: {
            Text(zoom == nil ? "Fit · \(Int((effectiveZoom * 100).rounded()))%" : "\(Int((effectiveZoom * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
        .help("How big the photo is shown: 100% is one photo pixel per screen pixel. ⌥-scroll or pinch to zoom, scroll to pan")
    }

    var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    // Long lists only show their start; the arrows still step through all of them.
                    ForEach(Array(samples.prefix(300).enumerated()), id: \.offset) { i, item in
                        // Click previews; the circle (or ⌘-click) ticks or unticks; ⇧-click ticks a range.
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), onCheck: { focused = true; tick(i) }, onTap: {
                            focused = true
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.shift) || mods.contains(.command) { tick(i) } else { clickedInStrip = true; index = i }
                        })
                        .id(i)
                        .help(item.url.lastPathComponent + (notes[item].map { " · \($0)" } ?? ""))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: 112)
            .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
            .environment(\.colorScheme, .dark)
            .help(excluded == nil ? "← → step through the photos" : "← → step through the photos; Space ticks or unticks the shown one")
            .onChange(of: index) {
                if clickedInStrip { clickedInStrip = false } else { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    var showGrid: Bool { gridMode && excluded != nil && samples.count > 1 }

    func isChecked(_ item: ToolItem) -> Bool? { excluded.map { !$0.wrappedValue.contains(item) } }

    /// Ticks or unticks a photo; with Shift, every photo from the last one clicked gets the same state.
    func tick(_ i: Int) {
        guard let excluded, i < samples.count else { return }
        let on = excluded.wrappedValue.contains(samples[i])
        let range = NSEvent.modifierFlags.contains(.shift) && anchor != nil ? min(anchor!, i)...max(anchor!, i) : i...i
        var set = excluded.wrappedValue
        for k in range where k < samples.count { if on { set.remove(samples[k]) } else { set.insert(samples[k]) } }
        excluded.wrappedValue = set
        anchor = i
    }

    var selectionBar: some View {
        let total = samples.count, off = excluded?.wrappedValue.count ?? 0
        return HStack(spacing: 10) {
            Picker("", selection: $gridMode) {
                Image(systemName: "photo").tag(false).help("Large preview")
                Image(systemName: "square.grid.3x3").tag(true).help("All photos as a grid, to tick many at once")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(off == 0 ? "All \(total) photos" : "\(total - off) of \(total) photos").monospacedDigit()
            if let item = current, !showGrid {
                Toggle("Include this one", isOn: Binding(get: { isChecked(item) ?? true }, set: { _ in tick(min(index, total - 1)) }))
                    .toggleStyle(.checkbox)
            }
            Spacer()
            Button("Select All") { excluded?.wrappedValue = [] }.disabled(off == 0)
            Button("Select None") { excluded?.wrappedValue = Set(samples) }.disabled(off == total)
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
        .environment(\.colorScheme, .dark)
    }

    /// Every photo, bigger: click to tick or untick (⇧-click for a range), double-click to preview it large. Arrow
    /// keys move the highlight, Space ticks it, Return opens it large.
    var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { i, item in
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), side: 150,
                                   onCheck: { focused = true; tick(i) }, onTap: { focused = true; index = i; tick(i) },
                                   onDoubleTap: { index = i; gridMode = false })
                            .id(i)
                            .help("\(item.url.lastPathComponent)\(item.personName.map { " · \($0)" } ?? "")\(notes[item].map { " · \($0)" } ?? "")")
                    }
                }
                .padding(12)
                .background(GeometryReader { g in
                    // As many 150 px thumbnails (8 px apart) as the row holds, for ↑ and ↓.
                    Color.clear.onChange(of: g.size.width, initial: true) { gridColumns = max(1, Int((g.size.width - 24 + 8) / 158)) }
                })
            }
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) { withAnimation { proxy.scrollTo(index, anchor: .center) } }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The shown photo's masks were asked for (Find Masks).
    var findsMasks: Bool { maskOverlay.masks(current?.url) != .notFound }

    func render() async {
        guard let item = current else { rendered = nil; return }
        // Let sliders settle; a newer change cancels this one.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        rendering = true
        let recipe = recipe, original = showOriginal, long = renderLongSide, withFull = perPhotoCrop, finds = findsMasks
        let mask = finds ? maskOverlay.part : nil
        // Strokes painted by now are in this render; on screen until it lands.
        let landed = liveStrokes.prefix { $0.done }.count
        let result = await Task.detached(priority: .userInitiated) {
            PreviewCache.shared.render(item, recipe: recipe, original: original, longSide: long, withFull: withFull, showMask: mask, findMasks: finds)
        }.value
        guard !Task.isCancelled else { return }
        rendering = false
        if let result { rendered = result }
        if let ok = result?.masks { maskOverlay.landed(item.url, found: ok) }
        liveStrokes.removeFirst(min(landed, liveStrokes.prefix { $0.done }.count))
        if !cropping { box = nil; liveAngle = liveZoom == nil ? nil : liveAngle }
        pan = clampedPan(pan)
    }
}

/// Scroll and pinch events over the preview, which SwiftUI has no gestures for on the Mac: scrolling pans,
/// ⌥-scrolling and pinching zoom. Points are in the view's coordinates, top-left origin.
struct EventCatcher: NSViewRepresentable {
    var onScroll: (CGPoint, CGSize, NSEvent.ModifierFlags) -> Void
    var onMagnify: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll
        v.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: ((CGPoint, CGSize, NSEvent.ModifierFlags) -> Void)?
        var onMagnify: ((CGPoint, CGFloat) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        // Never in the way of clicks and drags: the events come through the monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                if e.type == .magnify {
                    self.onMagnify?(p, e.magnification)
                } else {
                    let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8
                    self.onScroll?(p, CGSize(width: e.scrollingDeltaX * k, height: e.scrollingDeltaY * k), e.modifierFlags)
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// This photo's crop zoom: a slider from the largest crop that fits to four times closer, so the edges of an event
/// photo can be trimmed away without changing its shape. The preview shows the crop as the slider moves.
struct ZoomButton: View {
    let url: URL
    /// The slider's value while it is being dragged (nil when let go).
    @Binding var live: Double?
    var onLive: (Double?) -> Void = { _ in }
    @State private var open = false
    @State private var value = 1.0

    var own: Double? { CropPlacements.shared.zoom(for: url) }
    var title: String { String(format: "Zoom %.1f×", own ?? 1) }

    var body: some View {
        Button { value = own ?? 1; open = true } label: {
            // A fixed width, so the popover's anchor doesn't move as the value changes under it.
            Label(title, systemImage: "plus.magnifyingglass").frame(width: 78, alignment: .leading)
        }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(own == nil ? .white.opacity(0.85) : Color.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.vertical, 10)
            .help("Zoom this photo's crop in, to trim its edges (or use the crop tool, C)")
            .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zoom this photo's crop").font(.headline)
            HStack {
                Button { nudge(-0.1) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out a little")
                Slider(value: Binding(get: { value }, set: { value = $0; live = $0; onLive($0) }), in: 1...CropPlacements.maxZoom) { editing in
                    if !editing { save(); live = nil; onLive(nil) }
                }
                Button { nudge(0.1) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in a little")
                Text(String(format: "%.2f×", value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            HStack {
                Button("Largest Crop") { value = 1; save() }.disabled(own == nil)
                Spacer()
            }
            .controlSize(.small)
            Text(own != nil ? "Keeps the middle \(Int((100 / (own ?? 1)).rounded()))% of each side. Drag the photo in the preview to choose which part."
                 : "The crop is as large as the photo allows. Zoom in to trim the edges; the people stay in frame.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }

    func nudge(_ d: Double) { value = min(CropPlacements.maxZoom, max(1, ((value + d) * 10).rounded() / 10)); save() }

    func save() { CropPlacements.shared.set(zoom: value, for: url) }
}

struct StripThumb: View {
    let url: URL
    let selected: Bool
    /// nil = no tick circle; false = left out (dimmed).
    var checked: Bool? = nil
    var side: CGFloat = 96
    var onCheck: () -> Void = {}
    var onTap: () -> Void = {}
    var onDoubleTap: (() -> Void)? = nil
    @State private var image: NSImage?
    @State private var hoveringCheck = false
    /// Exported already (and the file is still there); crop edited by hand.
    @State private var exported = false
    @State private var edited = false

    /// The circle's click area: the top-right corner, bigger than the circle so it's easy to hit.
    var checkArea: CGFloat { side > 120 ? 46 : 38 }
    func inCheck(_ p: CGPoint) -> Bool { checked != nil && p.x >= side - checkArea && p.y <= checkArea }

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.08))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(checked == false ? 0.35 : 1)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accent : .clear, lineWidth: 3))
        .overlay(alignment: .topTrailing) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: side > 120 ? 22 : 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, checked ? Color.accent : Color.black.opacity(hoveringCheck ? 0.6 : 0.35))
                    .shadow(radius: 2)
                    .scaleEffect(hoveringCheck ? 1.15 : 1)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // One handler for the whole thumbnail, so a click on the circle always reaches it.
        .gesture(taps)
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoveringCheck = inCheck(p) } else { hoveringCheck = false }
        }
        .overlay(alignment: .bottomLeading) {
            if exported || edited {
                HStack(spacing: 3) {
                    if edited { Image(systemName: "crop") }
                    if exported { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                .font(.system(size: side > 120 ? 12 : 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(5)
                .allowsHitTesting(false)
            }
        }
        .task(id: url) {
            async let marks: Void = updateMarks()
            image = await Thumbnails.shared.media(url, time: nil, side: side)
            await marks
        }
        .onReceive(NotificationCenter.default.publisher(for: ExportHistory.changed)) { _ in Task { await updateMarks() } }
        .onReceive(NotificationCenter.default.publisher(for: CropPlacements.changed)) { _ in Task { await updateMarks() } }
    }

    func updateMarks() async {
        let url = url
        (exported, edited) = await Task.detached { (!ExportHistory.shared.exports(of: url).isEmpty, CropPlacements.shared.edit(for: url) != nil) }.value
    }

    /// Without a double-click action, single clicks act at once instead of waiting out the double-click interval.
    var taps: AnyGesture<Void> {
        let single = SpatialTapGesture().onEnded { v in if inCheck(v.location) { onCheck() } else { onTap() } }
        guard let onDoubleTap else { return AnyGesture(single.map { _ in () }) }
        return AnyGesture(SpatialTapGesture(count: 2)
            .onEnded { v in if !inCheck(v.location) { onDoubleTap() } }
            .exclusively(before: single)
            .map { _ in () })
    }
}

/// This photo's level: a slider to turn it by hand (fine-tuning or replacing the automatic straightening), back to
/// automatic, or not turned at all. The preview turns as the slider moves.
struct LevelButton: View {
    let url: URL
    let rendered: PreviewCache.Rendered
    /// The export straightens tilted photos.
    let straighten: Bool
    /// Degrees clockwise while the slider is being dragged (nil when let go).
    @Binding var live: Double?
    @State private var open = false
    @State private var value = 0.0

    /// Shown clockwise, as most editors do: turning a photo that leans left back to level is a positive turn.
    var own: Double? { CropPlacements.shared.rotation(for: url) }

    var title: String { String(format: "Level %+.1f°", -(rendered.angle ?? 0)) }

    var body: some View {
        Button { value = -(own ?? rendered.angle ?? 0); open = true } label: {
            Label(title, systemImage: "level").frame(width: 84, alignment: .leading)
        }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(own == nil ? .white.opacity(0.85) : Color.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.vertical, 10)
            .help("Turn this photo to level it (or draw a line along the horizon with the crop tool's Straighten)")
            .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Level this photo").font(.headline)
            HStack {
                Button { nudge(-0.1) } label: { Image(systemName: "rotate.left") }.help("0.1° anticlockwise")
                Slider(value: Binding(get: { value }, set: { value = $0; live = $0 }), in: -10...10) { editing in
                    if !editing { save(); live = nil }
                }
                Button { nudge(0.1) } label: { Image(systemName: "rotate.right") }.help("0.1° clockwise")
                Text(String(format: "%+.1f°", value)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            HStack {
                Button("Automatic") {
                    CropPlacements.shared.set(rotation: nil, for: url)
                    value = straighten ? -(rendered.autoAngle ?? 0) : 0
                }
                .disabled(own == nil)
                Button("Not Turned") { value = 0; save() }
                Spacer()
            }
            .controlSize(.small)
            Text(own != nil ? "Set by hand for this photo." :
                 !straighten ? "Tick “Straighten tilted photos” to level photos automatically, or turn this one by hand." :
                 rendered.autoAngle == nil ? "No clear vertical lines to level by: turn it by hand if it's tilted." :
                 String(format: "Levelled automatically by %+.1f°.", -(rendered.autoAngle ?? 0)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        // The preview is forced dark for its overlays; the popover is drawn in the system's own appearance, so its
        // contents must follow that, not the preview (white text on a light popover otherwise).
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }

    func nudge(_ d: Double) { value = min(10, max(-10, ((value + d) * 10).rounded() / 10)); save() }

    /// The slider's turn (clockwise, to a tenth of a degree) as this photo's own.
    func save() { CropPlacements.shared.set(rotation: -(value * 10).rounded() / 10, for: url) }
}

/// What auto tone set on each photo in the preview, by path: the editor's sliders show it under the user's own
/// changes, so what is applied is what is shown.
@MainActor
final class AutoToneValues: ObservableObject {
    static let shared = AutoToneValues()
    @Published private(set) var byPhoto: [String: Adjustments] = [:]

    func set(_ a: Adjustments?, for path: String) {
        if byPhoto[path] != a {
            if let a { byPhoto[path] = a } else { byPhoto[path] = nil }
        }
    }
}
