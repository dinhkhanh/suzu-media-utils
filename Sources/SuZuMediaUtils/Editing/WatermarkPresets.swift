import FaceLibrary
import Foundation
import GRDB
import MediaKit
import SwiftUI

struct WatermarkPreset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var spec: WatermarkSpec
}

/// Saved watermarks (logos, banners, text credits) to pick from in any editing screen. Each screen keeps its own
/// copy of the watermark it uses, so editing a preset never silently changes another screen or a delivery rule.
///
/// They live in the library (SavedWatermarks) once it is open, so they reach every Mac of the user's teams with
/// their logo files; the settings keep a copy for the moment before the library opens.
@MainActor
final class WatermarkPresets: ObservableObject {
    static let shared = WatermarkPresets()
    @Published private(set) var presets: [WatermarkPreset] = []
    private var store: LibraryStore?
    private var push: (@Sendable () -> Void)?
    private var observer: AnyDatabaseCancellable?

    init() {
        let d = UserDefaults.standard
        presets = d.data(forKey: "watermarkPresets").flatMap { try? JSONDecoder().decode([WatermarkPreset].self, from: $0) } ?? []
        // The single app-wide logo of earlier versions becomes the first preset.
        if presets.isEmpty, let old = d.data(forKey: "watermark").flatMap({ try? JSONDecoder().decode(WatermarkSpec.self, from: $0) }), !old.isEmpty {
            upsert(WatermarkPreset(name: ((old.logoPath as NSString).lastPathComponent as NSString).deletingPathExtension, spec: old))
        }
    }

    /// From now on the presets are the library's: this Mac's earlier ones go into it (as old, so a teammate's
    /// change to the same preset wins), and the list follows the library, teammates' changes included.
    func attach(_ store: LibraryStore, push: @escaping @Sendable () -> Void) {
        self.store = store
        self.push = push
        let mine = presets
        try? store.db.write { db in
            for p in mine where try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watermarkPreset WHERE id = ?", arguments: [p.id]) == 0 {
                try SavedWatermarks.save(SavedWatermark(id: p.id, name: p.name, spec: p.spec), db: db, at: 1)
            }
        }
        if !mine.isEmpty { push() }
        observer = ValueObservation.tracking { db in try SavedWatermarks.all(db) }
            .start(in: store.db, scheduling: .async(onQueue: .main), onError: { _ in }) { [weak self] saved in
                MainActor.assumeIsolated { self?.show(saved.map { WatermarkPreset(id: $0.id, name: $0.name, spec: $0.spec) }) }
            }
    }

    private func show(_ list: [WatermarkPreset]) {
        guard list != presets else { return }
        presets = list
        cache()
    }

    func preset(_ id: String?) -> WatermarkPreset? { presets.first { $0.id == id } }

    /// Adds the preset, or replaces the one with the same id. Returns it as saved (its spec knows its preset).
    @discardableResult
    func upsert(_ preset: WatermarkPreset) -> WatermarkPreset {
        var p = preset
        p.spec.presetId = p.id
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        cache()
        if let store {
            try? store.db.write { db in try SavedWatermarks.save(SavedWatermark(id: p.id, name: p.name, spec: p.spec), db: db) }
            push?()
        }
        return p
    }

    func delete(_ id: String) {
        presets.removeAll { $0.id == id }
        cache()
        if let store {
            try? store.db.write { db in try SavedWatermarks.delete(id, db: db) }
            push?()
        }
    }

    private func cache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "watermarkPresets")
    }
}

/// Each screen's own editing choices (crop, size, watermark…), remembered between uses.
enum FeatureEdits {
    static var defaultStrength: Double {
        get { UserDefaults.standard.object(forKey: "autoToneStrength") as? Double ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "autoToneStrength") }
    }

    static func load(_ key: String) -> EditRecipe {
        if let r = UserDefaults.standard.data(forKey: "edits.\(key)").flatMap({ try? JSONDecoder().decode(EditRecipe.self, from: $0) }) { return r }
        var r = EditRecipe()
        r.autoToneStrength = defaultStrength
        return r
    }

    static func save(_ recipe: EditRecipe, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipe), forKey: "edits.\(key)")
    }
}

extension View {
    /// Loads this screen's last edit choices when it appears and remembers changes.
    func rememberEdits(_ key: String?, recipe: Binding<EditRecipe>) -> some View {
        modifier(RememberEdits(key: key, recipe: recipe))
    }
}

struct RememberEdits: ViewModifier {
    let key: String?
    @Binding var recipe: EditRecipe
    @State private var loaded = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let key, !loaded else { return }
                loaded = true
                recipe = FeatureEdits.load(key)
            }
            .onChange(of: recipe) { if let key, loaded { FeatureEdits.save(recipe, key) } }
    }
}
