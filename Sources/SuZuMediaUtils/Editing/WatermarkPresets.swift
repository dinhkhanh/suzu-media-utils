import Foundation
import MediaKit
import SwiftUI

struct WatermarkPreset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var spec: WatermarkSpec
}

/// Saved watermarks (logos, text credits) to pick from in any editing screen. Each screen keeps its own copy of the
/// watermark it uses, so editing a preset never silently changes another screen or a delivery rule.
@MainActor
final class WatermarkPresets: ObservableObject {
    static let shared = WatermarkPresets()
    @Published private(set) var presets: [WatermarkPreset] = []

    init() {
        let d = UserDefaults.standard
        presets = d.data(forKey: "watermarkPresets").flatMap { try? JSONDecoder().decode([WatermarkPreset].self, from: $0) } ?? []
        // The single app-wide logo of earlier versions becomes the first preset.
        if presets.isEmpty, let old = d.data(forKey: "watermark").flatMap({ try? JSONDecoder().decode(WatermarkSpec.self, from: $0) }), !old.isEmpty {
            upsert(WatermarkPreset(name: ((old.logoPath as NSString).lastPathComponent as NSString).deletingPathExtension, spec: old))
        }
    }

    func preset(_ id: String?) -> WatermarkPreset? { presets.first { $0.id == id } }

    /// Adds the preset, or replaces the one with the same id. Returns it as saved (its spec knows its preset).
    @discardableResult
    func upsert(_ preset: WatermarkPreset) -> WatermarkPreset {
        var p = preset
        p.spec.presetId = p.id
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        save()
        return p
    }

    func delete(_ id: String) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func save() {
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
