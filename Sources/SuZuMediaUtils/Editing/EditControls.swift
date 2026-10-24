import FaceLibrary
import MediaKit
import SwiftUI

/// Which groups of edit controls a screen offers.
struct EditSections: OptionSet {
    let rawValue: Int
    static let tone = EditSections(rawValue: 1)
    static let crop = EditSections(rawValue: 2)
    static let watermark = EditSections(rawValue: 4)
    static let size = EditSections(rawValue: 8)
    static let all: EditSections = [.tone, .crop, .watermark, .size]
}

/// A titled group in an inspector column.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The edit settings, as an inspector column: look, crop, watermark, size.
struct EditControls: View {
    @Binding var recipe: EditRecipe
    var sections: EditSections = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if sections.contains(.tone) {
                InspectorSection(title: "Look") {
                    Toggle("Auto tone & enhance", isOn: $recipe.autoTone)
                        .help("Exposure, contrast, shadows/highlights, vibrance and skin-tone balance; on automatically with crops and watermarks")
                    if recipe.autoTone { PercentSlider(label: "Strength", value: $recipe.autoToneStrength, range: 0.2...1) }
                    Toggle("Straighten tilted photos", isOn: Binding(get: { recipe.straighten == true }, set: { recipe.straighten = $0 ? true : nil }))
                        .help("Levels photos turned up to 10° off, by their vertical lines (pillars, door frames, screen edges), and trims the corners. Photos without clear lines are left as they are; turn any photo by hand with Level in the preview.")
                }
            }
            if sections.contains(.crop) {
                InspectorSection(title: "Crop") { AspectChooser(recipe: $recipe) }
            }
            if sections.contains(.watermark) {
                InspectorSection(title: "Watermark") { WatermarkControls(spec: $recipe.watermark) }
            }
            if sections.contains(.size) {
                InspectorSection(title: "Size & quality") {
                    Picker("Long side", selection: $recipe.maxLongSide) {
                        Text("Original").tag(Int?.none)
                        if recipe.crops {
                            Text("\(AspectPreset.socialLongSide) px (recommended)").tag(Int?.some(AspectPreset.socialLongSide))
                        }
                        // A platform's own size only fits one crop shape.
                        if let a = platformAspect {
                            Text("\(a.platformLongSide) px (\(a.platformName) size)").tag(Int?.some(a.platformLongSide))
                        }
                        ForEach([3000, 2048, 1600, 1080].filter { !recipe.crops || ($0 != AspectPreset.socialLongSide && $0 != platformAspect?.platformLongSide) },
                                id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                    }
                    Picker("Format", selection: Binding(get: { recipe.outputFormat }, set: { recipe.format = $0 == .jpeg ? nil : $0 })) {
                        ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if recipe.outputFormat == .jpeg {
                        PercentSlider(label: "JPEG quality", value: $recipe.jpegQuality, range: 0.6...1)
                    } else {
                        Text("Lossless, in the photo's own colours (16-bit when the original is). Files are several times larger than JPEG.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // Photos going out with a social crop or a watermark are auto-toned too (can still be switched off).
        // Crops go out at 2048 px (a platform's own size follows the crop); the original frame keeps the original size.
        .onChange(of: platformAspect) { old, new in
            if let old, recipe.maxLongSide == old.platformLongSide {
                recipe.maxLongSide = new?.platformLongSide ?? (recipe.crops ? AspectPreset.socialLongSide : nil)
            }
        }
        .onChange(of: recipe.crops) { _, crops in
            if crops {
                recipe.autoTone = true
                if recipe.maxLongSide == nil { recipe.maxLongSide = AspectPreset.socialLongSide }
            } else if recipe.maxLongSide == AspectPreset.socialLongSide {
                recipe.maxLongSide = nil
            }
        }
        .onChange(of: recipe.watermark == nil) { wasNil, isNil in if wasNil && !isNil { recipe.autoTone = true } }
    }
}

extension EditControls {
    /// The single crop shape every photo gets, when there is one.
    var platformAspect: AspectPreset? { recipe.cropByOrientation == true ? nil : recipe.aspect }
}

struct PercentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Crop presets as little frames of their shape. A click crops every photo; ⌘-click a second one to split them by
/// orientation: the taller shape for portrait photos, the wider one for landscape photos (with Original, the other
/// kind keeps its frame).
struct AspectChooser: View {
    @Binding var recipe: EditRecipe

    var byOrientation: Bool { recipe.cropByOrientation == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                option(nil, "Original", ratio: 1.5, help: "Keep the original frame")
                ForEach(AspectPreset.allCases) { a in option(a, a.rawValue, ratio: a.ratio, help: a.label) }
            }
            Text(byOrientation ? "Portrait photos: \(name(recipe.portraitAspect)) · Landscape photos: \(name(recipe.aspect))"
                 : "⌘-click a second shape to crop portraits and landscapes differently.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func name(_ a: AspectPreset?) -> String { a?.rawValue ?? "original" }

    /// -1 portrait shape, 1 landscape shape, 0 either (square or the photo's own frame).
    static func side(_ a: AspectPreset?) -> Int { a.map { $0.ratio < 1 ? -1 : $0.ratio > 1 ? 1 : 0 } ?? 0 }

    /// Two picks as (portrait, landscape), or nil when they are the same kind (the new one then replaces the old).
    static func pair(_ a: AspectPreset?, _ b: AspectPreset?) -> (portrait: AspectPreset?, landscape: AspectPreset?)? {
        switch (side(a), side(b)) {
        case (-1, 1), (-1, 0), (0, 1): (a, b)
        case (1, -1), (0, -1), (1, 0): (b, a)
        default: nil
        }
    }

    func label(_ value: AspectPreset?) -> String? {
        guard byOrientation else { return nil }
        return value == recipe.portraitAspect ? "Portraits" : value == recipe.aspect ? "Landscapes" : nil
    }

    func isSelected(_ value: AspectPreset?) -> Bool {
        byOrientation ? value == recipe.portraitAspect || value == recipe.aspect : value == recipe.aspect
    }

    func set(all: AspectPreset?) { recipe.aspect = all; recipe.cropByOrientation = nil; recipe.portraitAspect = nil }

    func tap(_ value: AspectPreset?) {
        guard NSEvent.modifierFlags.contains(.command) else { return set(all: value) }
        if byOrientation {
            // Unpicking one leaves the other for every photo.
            if value == recipe.portraitAspect { return set(all: recipe.aspect) }
            if value == recipe.aspect { return set(all: recipe.portraitAspect) }
            switch Self.side(value) {
            case -1: recipe.portraitAspect = value
            case 1: recipe.aspect = value
            default: set(all: value)
            }
        } else if value == recipe.aspect {
            set(all: nil)
        } else if let p = Self.pair(value, recipe.aspect) {
            recipe.cropByOrientation = true
            recipe.portraitAspect = p.portrait
            recipe.aspect = p.landscape
        } else {
            set(all: value)
        }
    }

    func option(_ value: AspectPreset?, _ title: String, ratio: Double, help: String) -> some View {
        let selected = isSelected(value)
        return Button { tap(value) } label: {
            VStack(spacing: 4) {
                ZStack {
                    let w = ratio >= 1 ? 30.0 : 30.0 * ratio, h = ratio >= 1 ? 30.0 / ratio : 30.0
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: value == nil ? [3, 2] : []))
                        .frame(width: w, height: h)
                }
                .frame(height: 32)
                Text(title).font(.caption)
                if let l = label(value) { Text(l).font(.caption2.weight(.medium)) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accent : .primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accent.opacity(0.15) : Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help). ⌘-click to pair it with a second shape: one for portrait photos, one for landscape photos.")
    }
}

/// Pick a saved watermark, or none; edit it in place; save edits back to the preset or as a new one.
struct WatermarkControls: View {
    @Binding var spec: WatermarkSpec?
    @ObservedObject private var presets = WatermarkPresets.shared
    @Environment(\.openSettings) private var openSettings
    @State private var naming = false
    @State private var newName = ""

    var preset: WatermarkPreset? { presets.preset(spec?.presetId) }
    var edited: Bool {
        guard let spec else { return false }
        return preset.map { !spec.sameLook(as: $0.spec) } ?? true
    }
    var title: String {
        guard spec != nil else { return "None" }
        return preset.map { $0.name + (edited ? " (edited)" : "") } ?? "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preset")
                Spacer()
                Menu(title) {
                    Button("None") { spec = nil }
                    if !presets.presets.isEmpty { Divider() }
                    ForEach(presets.presets) { p in Button(p.name) { spec = p.spec } }
                    Divider()
                    Button("New Logo Watermark…") { chooseLogo { spec = WatermarkSpec(logoPath: $0) } }
                    Button("New Text Watermark") { spec = WatermarkSpec(text: "© SuZu Media") }
                    Button("New Banner Watermark…") { chooseBanner { spec = WatermarkSpec(banner: $0) } }
                    Divider()
                    Button("Manage Presets…") { openSettings() }
                }
                .fixedSize()
            }
            if spec != nil {
                WatermarkFields(spec: Binding(get: { spec ?? WatermarkSpec(logoPath: "") }, set: { spec = $0 }))
                if edited && !(spec?.isEmpty ?? true) {
                    HStack {
                        if let preset {
                            Button("Update “\(preset.name)”") {
                                var p = preset
                                p.spec = spec!
                                spec = presets.upsert(p).spec
                            }
                        }
                        Button("Save as Preset…") { naming = true }
                    }
                    .controlSize(.small)
                }
            }
        }
        .alert("Save Watermark Preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let s = spec { spec = presets.upsert(WatermarkPreset(name: newName.isEmpty ? "Watermark \(presets.presets.count + 1)" : newName, spec: s)).spec }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Presets can be picked in every editing screen.")
        }
    }
}

@MainActor func chooseLogo(_ done: @escaping (String) -> Void) {
    Panels.choose(folders: false, files: true, types: [.png, .jpeg, .tiff, .heic], prompt: "Use Logo",
                  message: "A PNG with a transparent background works best.") { if let u = $0.first { done(u.path) } }
}

@MainActor func chooseBanner(portrait: Bool = false, _ done: @escaping (String) -> Void) {
    Panels.choose(folders: false, files: true, types: [.png, .jpeg, .tiff, .heic], prompt: "Use Banner",
                  message: portrait ? "The banner for portrait photos (taller than wide)."
                      : "A wide bar across the whole photo (its sides are trimmed to fit): the one for landscape and square photos.") { if let u = $0.first { done(u.path) } }
}

/// What a watermark is: a small logo, a line of text, or a banner across the whole width.
enum WatermarkKind: Hashable { case logo, text, banner }

/// The look of one watermark: logo or text, where it sits, how big and how strong.
struct WatermarkFields: View {
    @Binding var spec: WatermarkSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: kind) {
                Text("Logo").tag(WatermarkKind.logo)
                Text("Text").tag(WatermarkKind.text)
                Text("Banner").tag(WatermarkKind.banner)
            }
            .pickerStyle(.segmented).labelsHidden()
            if spec.isBanner {
                fileRow("Landscape", path: spec.logoPath, placeholder: "No banner chosen") { chooseBanner { spec.logoPath = $0 } }
                fileRow("Portrait", path: spec.portraitLogoPath ?? "", placeholder: "Same as landscape") {
                    chooseBanner(portrait: true) { spec.portraitLogoPath = $0 }
                }
                HStack {
                    Text("Height").lineLimit(1).frame(width: 76, alignment: .leading)
                    TextField("", value: bannerPixels, format: .number).textFieldStyle(.roundedBorder).frame(width: 56)
                    Stepper("", value: bannerPixels, in: 20...400).labelsHidden()
                    Text("px per \(Int(WatermarkSpec.bannerReferenceSide)) px").foregroundStyle(.secondary)
                }
                Text("The same height on every photo, measured on the long side. The banner is centred and its sides are trimmed to the photo's width, so make it wider than any photo and keep text and logos in the middle (one too narrow is stretched sideways). Photos taller than wide get the portrait banner.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Position", selection: Binding(get: { [.top, .center, .bottom][WatermarkSpec.Position.allCases.firstIndex(of: spec.position)! / 3] },
                                                      set: { spec.position = $0 })) {
                    Text("Top").tag(WatermarkSpec.Position.top)
                    Text("Middle").tag(WatermarkSpec.Position.center)
                    Text("Bottom").tag(WatermarkSpec.Position.bottom)
                }
                .pickerStyle(.segmented)
                CompactSlider(label: "Opacity", value: $spec.opacity, range: 0.15...1)
                CompactSlider(label: "Margin", value: $spec.margin, range: 0...0.12)
            } else if spec.text != nil {
                TextField("Text", text: Binding(get: { spec.text ?? "" }, set: { spec.text = $0 }), prompt: Text("© SuZu Media"))
                    .textFieldStyle(.roundedBorder)
                Picker("Colour", selection: Binding(get: { spec.textColor ?? .white }, set: { spec.textColor = $0 })) {
                    Text("White").tag(WatermarkSpec.TextColor.white)
                    Text("Black").tag(WatermarkSpec.TextColor.black)
                }
                .pickerStyle(.segmented)
            } else {
                HStack {
                    Image(systemName: "photo")
                    Text(spec.logoPath.isEmpty ? "No logo chosen" : (spec.logoPath as NSString).lastPathComponent)
                        .foregroundStyle(spec.logoPath.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        .help(spec.logoPath)
                    Spacer()
                    Button("Choose…") { chooseLogo { spec.logoPath = $0 } }
                }
            }
            if !spec.isBanner {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Position").font(.caption).foregroundStyle(.secondary)
                        AlignmentGrid(position: $spec.position)
                    }
                    VStack(spacing: 2) {
                        CompactSlider(label: "Size", value: $spec.size, range: 0.06...0.6)
                        CompactSlider(label: "Opacity", value: $spec.opacity, range: 0.15...1)
                        CompactSlider(label: "Margin", value: $spec.margin, range: 0...0.12)
                    }
                }
            }
        }
    }

    var kind: Binding<WatermarkKind> {
        Binding(get: { spec.isBanner ? .banner : spec.text != nil ? .text : .logo }, set: { k in
            let wasBanner = spec.isBanner
            spec.text = k == .text ? (spec.text ?? "© SuZu Media") : nil
            spec.banner = k == .banner ? true : nil
            // A banner sits flush on an edge at full strength; a mark goes back to the corner.
            if k == .banner && !wasBanner { spec.position = .bottom; spec.margin = 0; spec.opacity = 1 }
            if k != .banner && wasBanner { spec.position = .bottomRight; spec.margin = 0.035 }
        })
    }

    /// Banner height in pixels on a photo 2048 px on the long side.
    var bannerPixels: Binding<Int> {
        Binding(get: { Int(((spec.bannerHeight ?? WatermarkSpec.defaultBannerHeight) * WatermarkSpec.bannerReferenceSide).rounded()) },
                set: { spec.bannerHeight = Double(min(max($0, 20), 400)) / WatermarkSpec.bannerReferenceSide })
    }

    func fileRow(_ label: String, path: String, placeholder: String, choose: @escaping () -> Void) -> some View {
        HStack {
            Text(label).lineLimit(1).frame(width: 76, alignment: .leading)
            Text(path.isEmpty ? placeholder : (path as NSString).lastPathComponent)
                .foregroundStyle(path.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                .help(path)
            Spacer()
            Button("Choose…", action: choose)
        }
    }
}

struct CompactSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// Nine spots on a little picture frame; the filled one is where the watermark goes.
struct AlignmentGrid: View {
    @Binding var position: WatermarkSpec.Position

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        let p = WatermarkSpec.Position.allCases[row * 3 + col]
                        Button { position = p } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(p == position ? Color.accent : Color.secondary.opacity(0.22))
                                .frame(width: 24, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(p.label)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
    }
}

/// Preview and controls side by side, for dialogs (export, delivery rules, gallery, video stills).
struct EditOptionsView: View {
    @Binding var recipe: EditRecipe
    /// Photos to preview the edit on.
    var samples: [ToolItem]
    var sections: EditSections = .all
    /// Remembers this screen's choices between uses.
    var remember: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            EditPreview(recipe: $recipe, samples: samples)
                .frame(minWidth: 360, maxWidth: .infinity)
            Divider()
            ScrollView {
                EditControls(recipe: $recipe, sections: sections).padding(14)
            }
            .frame(width: 290)
        }
        .frame(height: 470)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .rememberEdits(remember, recipe: $recipe)
    }
}

/// Settings → Watermarks: the saved presets, and the default auto-tone strength.
struct WatermarkSettings: View {
    @EnvironmentObject var model: FaceGroupingModel
    @ObservedObject private var presets = WatermarkPresets.shared
    @State private var selection: String?
    @State private var draft: WatermarkPreset?
    @State private var samples: [ToolItem] = []
    @State private var strength = FeatureEdits.defaultStrength

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(presets.presets) { p in
                            Label(p.name, systemImage: p.spec.isText ? "textformat" : p.spec.isBanner ? "rectangle.bottomthird.inset.filled" : "photo").tag(p.id)
                        }
                    }
                    .frame(width: 190)
                    HStack(spacing: 0) {
                        Menu {
                            Button("Logo…") { chooseLogo { add(WatermarkSpec(logoPath: $0), name: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension) } }
                            Button("Text") { add(WatermarkSpec(text: "© SuZu Media"), name: "Text credit") }
                            Button("Banner…") { chooseBanner { add(WatermarkSpec(banner: $0), name: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension) } }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                        Button { if let s = selection { presets.delete(s); selection = presets.presets.first?.id } } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).frame(width: 28).disabled(selection == nil)
                        Spacer()
                    }
                    .padding(4)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                if let binding = draftBinding {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: binding.name).textFieldStyle(.roundedBorder).font(.headline)
                        HStack(alignment: .top, spacing: 14) {
                            EditPreview(recipe: Binding(get: { previewRecipe }, set: { r in if let w = r.watermark { draft?.spec = w } }),
                                        samples: samples, filmstrip: false, perPhotoCrop: false)
                                .frame(width: 320, height: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            WatermarkFields(spec: binding.spec).frame(width: 260)
                        }
                    }
                } else {
                    ContentUnavailableView("No watermark presets", systemImage: "seal",
                                           description: Text("Add a logo, a text credit or a full-width banner with +. Every editing screen can use them, each with its own position and size."))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 320)
            Divider()
            HStack {
                Text("Default auto-tone strength for new screens")
                Slider(value: $strength, in: 0.2...1).frame(width: 180)
                Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 40)
            }
            Text("Each editing screen (Batch Export, Copy/Move, delivery rules, web gallery, video stills) remembers its own crop, size and watermark.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 820)
        .onAppear { selection = selection ?? presets.presets.first?.id }
        .onChange(of: selection, initial: true) { draft = presets.preset(selection) }
        .onChange(of: draft) { if let d = draft, d != presets.preset(d.id) { presets.upsert(d) } }
        .onChange(of: strength) { FeatureEdits.defaultStrength = strength }
        .task { samples = await model.samples(limit: 6) }
    }

    var draftBinding: Binding<WatermarkPreset>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft! }, set: { draft = $0 })
    }

    var previewRecipe: EditRecipe {
        var r = EditRecipe()
        r.watermark = draft?.spec
        return r
    }

    func add(_ spec: WatermarkSpec, name: String) {
        let p = presets.upsert(WatermarkPreset(name: name, spec: spec))
        selection = p.id
    }
}
