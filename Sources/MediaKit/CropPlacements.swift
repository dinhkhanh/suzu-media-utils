import CoreGraphics
import Foundation

/// A photo's own crop shape, instead of the one the export uses.
public enum CropShape: Codable, Sendable, Hashable {
    case original
    case preset(AspectPreset)

    public var aspect: AspectPreset? { if case .preset(let a) = self { a } else { nil } }
    public var label: String { aspect?.rawValue ?? "Original" }
}

/// Crops edited by hand, per file: where the crop sits (the photo dragged in the preview) and the photo's own crop
/// shape. They hold for every screen that exports the file, until they're reset.
public final class CropPlacements: @unchecked Sendable {
    public static let shared = CropPlacements()
    /// Posted on the main queue when a photo's crop is edited or reset.
    public static let changed = Notification.Name("CropPlacements.changed")

    public struct Edit: Codable, Sendable, Hashable {
        /// The crop's centre, normalized, top-left origin; it fits every crop shape.
        public var center: CGPoint?
        public var shape: CropShape?
        /// Degrees to turn this photo (0: not at all), instead of the export's straightening.
        public var rotation: Double?
        /// How far the crop is zoomed in (1…`maxZoom`): the crop is 1/zoom of the largest that fits, so the edges are
        /// trimmed even when the photo keeps its shape.
        public var zoom: Double?
        /// A crop drawn by hand in any shape (normalized, top-left origin, of the levelled photo); wins over the rest.
        public var rect: CGRect?
        /// This photo's own light, colour, detail and orientation, instead of the export's.
        public var adjustments: Adjustments?
        public var isEmpty: Bool { center == nil && shape == nil && rotation == nil && zoom == nil && rect == nil && adjustments == nil }
        /// Something about the crop was set by hand.
        public var cropEdited: Bool { center != nil || zoom != nil || rect != nil }
    }

    /// The furthest a crop can zoom in (a quarter of each side).
    public static let maxZoom = 4.0

    private static let key = "cropEdits"
    private let lock = NSLock()
    private var edits: [String: Edit]

    init() {
        let d = UserDefaults.standard
        edits = d.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Edit].self, from: $0) } ?? [:]
        // Crop centres saved by the first version (centres only).
        if let old = d.dictionary(forKey: "cropPlacements") as? [String: [Double]] {
            for (path, c) in old where c.count == 2 && edits[path] == nil { edits[path] = Edit(center: CGPoint(x: c[0], y: c[1])) }
            d.removeObject(forKey: "cropPlacements")
            save()
        }
    }

    public func edit(for url: URL) -> Edit? { lock.withLock { edits[url.path] } }
    /// The edits of these files, for undo.
    public func edits(for urls: [URL]) -> [String: Edit] {
        // A photo may be listed twice (under two people): the same edit either way.
        lock.withLock { Dictionary(urls.compactMap { u in edits[u.path].map { (u.path, $0) } }, uniquingKeysWith: { a, _ in a }) }
    }
    /// Puts these files' edits back (nil removes one), for undo.
    public func restore(_ snapshot: [String: Edit?]) {
        let changed = lock.withLock {
            var any = false
            for (path, e) in snapshot where edits[path] != e { edits[path] = e; any = true }
            return any
        }
        if changed { save() }
    }
    public func center(for url: URL) -> CGPoint? { edit(for: url)?.center }
    public func shape(for url: URL) -> CropShape? { edit(for: url)?.shape }
    public func rotation(for url: URL) -> Double? { edit(for: url)?.rotation }
    public func zoom(for url: URL) -> Double? { edit(for: url)?.zoom }
    public func rect(for url: URL) -> CGRect? { edit(for: url)?.rect }
    public func adjustments(for url: URL) -> Adjustments? { edit(for: url)?.adjustments }

    /// nil goes back to the automatic placement.
    public func set(_ center: CGPoint?, for url: URL) { update(url) { $0.center = center } }
    /// nil (or 1) goes back to the largest crop that fits. Clamped to 1…`maxZoom`, to a hundredth.
    public func set(zoom: Double?, for url: URL) { update(url) { $0.zoom = Self.clamp(zoom); $0.rect = nil } }
    /// Both at once (a pinch zooms about a point): the crop as zoomed and placed.
    public func set(zoom: Double?, center: CGPoint?, for url: URL) { update(url) { $0.zoom = Self.clamp(zoom); $0.center = center; $0.rect = nil } }
    /// A crop drawn by hand, in any shape: it replaces the zoom and placement. nil goes back to the shaped crop.
    public func set(rect: CGRect?, for url: URL) { update(url) { $0.rect = rect; if rect != nil { $0.zoom = nil; $0.center = nil } } }
    /// This photo's own adjustments; nil goes back to the export's.
    public func set(adjustments: Adjustments?, for url: URL) { update(url) { $0.adjustments = adjustments.flatMap { $0.isEmpty ? nil : $0 } } }
    /// Back to the automatic crop: placement, zoom and any crop drawn by hand (the shape and turn stay).
    public func resetPlacement(for url: URL) { update(url) { $0.center = nil; $0.zoom = nil; $0.rect = nil } }

    static func clamp(_ zoom: Double?) -> Double? {
        guard let zoom else { return nil }
        let z = (min(max(zoom, 1), maxZoom) * 100).rounded() / 100
        return z <= 1 ? nil : z
    }
    /// nil goes back to the export's crop shape.
    public func set(shape: CropShape?, for url: URL) { update(url) { $0.shape = shape } }
    /// nil goes back to the export's straightening.
    public func set(rotation: Double?, for url: URL) { update(url) { $0.rotation = rotation } }

    private func update(_ url: URL, _ change: (inout Edit) -> Void) {
        let changed = lock.withLock {
            let old = edits[url.path]
            var e = old ?? Edit()
            change(&e)
            let new: Edit? = e.isEmpty ? nil : e
            edits[url.path] = new
            return new != old
        }
        if changed { save() }
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(edits) }
        UserDefaults.standard.set(data, forKey: Self.key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// The crop focus for this file: the hand-placed centre and zoom when there are any (with a centre, faces are not
    /// needed; with only a zoom, the faces still place the smaller crop), else `given`.
    public func focus(for url: URL, given: FocusHint?) -> FocusHint? {
        guard let e = edit(for: url), e.cropEdited else { return given }
        var f = given ?? FocusHint(primary: nil)
        f.center = e.center
        f.zoom = e.zoom
        f.rect = e.rect
        return f
    }

    /// The recipe for this file: its own crop shape and turn, when it has them, instead of the export's.
    public func recipe(_ recipe: EditRecipe, for url: URL) -> EditRecipe {
        guard let e = edit(for: url) else { return recipe }
        var r = recipe
        if let s = e.shape {
            r.aspect = s.aspect
            r.cropByOrientation = nil
            r.portraitAspect = nil
        }
        if let turn = e.rotation { r.rotation = turn }
        if let a = e.adjustments { r.look = a }
        return r
    }
}
