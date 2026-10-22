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
        public var isEmpty: Bool { center == nil && shape == nil && rotation == nil }
    }

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
    public func center(for url: URL) -> CGPoint? { edit(for: url)?.center }
    public func shape(for url: URL) -> CropShape? { edit(for: url)?.shape }
    public func rotation(for url: URL) -> Double? { edit(for: url)?.rotation }

    /// nil goes back to the automatic placement.
    public func set(_ center: CGPoint?, for url: URL) { update(url) { $0.center = center } }
    /// nil goes back to the export's crop shape.
    public func set(shape: CropShape?, for url: URL) { update(url) { $0.shape = shape } }
    /// nil goes back to the export's straightening.
    public func set(rotation: Double?, for url: URL) { update(url) { $0.rotation = rotation } }

    private func update(_ url: URL, _ change: (inout Edit) -> Void) {
        lock.withLock {
            var e = edits[url.path] ?? Edit()
            change(&e)
            edits[url.path] = e.isEmpty ? nil : e
        }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(edits) }
        UserDefaults.standard.set(data, forKey: Self.key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// The crop focus for this file: the hand-placed centre when there is one (faces are then not needed), else `given`.
    public func focus(for url: URL, given: FocusHint?) -> FocusHint? {
        guard let c = center(for: url) else { return given }
        var f = given ?? FocusHint(primary: nil)
        f.center = c
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
        return r
    }
}
