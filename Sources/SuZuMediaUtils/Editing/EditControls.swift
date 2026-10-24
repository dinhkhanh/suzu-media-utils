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

/// The edit settings, as an inspector column: look (light, colour, detail), orientation, crop, watermark, size.
/// With `photo` and more than one photo, the look can be set for that photo alone.
struct EditControls: View {
    @Binding var recipe: EditRecipe
    var sections: EditSections = .all
    /// The photo shown in the preview, for "This photo only".
    var photo: URL? = nil
    var photoCount = 1
    /// Edits the shown photo's own look instead of the export's.
    @State private var thisPhoto = false
    @State private var placements = 0
    @AppStorage("edit.curveOpen") private var curveOpen = false
    @AppStorage("edit.hslOpen") private var hslOpen = false
    @ObservedObject private var userLooks = UserLooks.shared
    @State private var savingLook = false
    @State private var lookName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if sections.contains(.tone) {
                InspectorSection(title: "Look") {
                    scopePicker
                    HStack {
                        Toggle("Auto tone & enhance", isOn: $recipe.autoTone)
                            .help("Exposure, contrast, shadows/highlights, vibrance and skin-tone balance; on automatically with crops and watermarks")
                        Spacer()
                        looksMenu
                    }
                    if recipe.autoTone { PercentSlider(label: "Strength", value: $recipe.autoToneStrength, range: 0.2...1) }
                    Toggle("Straighten tilted photos", isOn: Binding(get: { recipe.straighten == true }, set: { recipe.straighten = $0 ? true : nil }))
                        .help("Levels photos turned up to 10° off, by their vertical lines (pillars, door frames, screen edges), and trims the corners. Photos without clear lines are left as they are; turn any photo by hand with Level in the preview.")
                }
                InspectorSection(title: "Light") {
                    AdjustSlider("Exposure", value: look.exposure, range: -2...2, unit: " EV")
                    AdjustSlider("Contrast", value: look.contrast)
                    AdjustSlider("Highlights", value: look.highlights)
                    AdjustSlider("Shadows", value: look.shadows)
                }
                InspectorSection(title: "Colour") {
                    AdjustSlider("Temperature", value: look.temperature, help: "Left cooler (bluer), right warmer (more yellow)")
                    AdjustSlider("Tint", value: look.tint, help: "Left greener, right more magenta")
                    AdjustSlider("Vibrance", value: look.vibrance, help: "Boosts muted colours and spares skin tones")
                    AdjustSlider("Saturation", value: look.saturation)
                    Toggle("Black & white", isOn: look.monochrome)
                }
                DisclosureGroup(isExpanded: $curveOpen) {
                    CurveEditor(points: look.tone).padding(.top, 6)
                } label: {
                    HStack {
                        Text("TONE CURVE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if look.wrappedValue.hasCurve { Button("Reset") { look.tone.wrappedValue = Adjustments.straightCurve }.controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { curveOpen.toggle() }
                }
                DisclosureGroup(isExpanded: $hslOpen) {
                    HSLControls(hsl: look.colours).padding(.top, 6)
                } label: {
                    HStack {
                        Text("HSL · COLOUR BY COLOUR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if look.wrappedValue.hsl != nil { Button("Reset") { look.colours.wrappedValue = HSLAdjust() }.controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { hslOpen.toggle() }
                }
                InspectorSection(title: "Detail") {
                    AdjustSlider("Sharpen", value: look.sharpness, range: 0...1)
                    AdjustSlider("Clarity", value: look.clarity, range: 0...1, help: "Local contrast: more bite in the midtones")
                    AdjustSlider("Vignette", value: look.vignette, range: 0...1, help: "Darkens the corners")
                }
                InspectorSection(title: "Orientation") {
                    HStack(spacing: 6) {
                        Button { turn(-1) } label: { Image(systemName: "rotate.left") }.help("Turn anticlockwise (⌘[)")
                        Button { turn(1) } label: { Image(systemName: "rotate.right") }.help("Turn clockwise (⌘])")
                        Button { look.flipHorizontal.wrappedValue.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            .help("Flip left to right")
                        Button { look.flipVertical.wrappedValue.toggle() } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                            .help("Flip top to bottom")
                        Spacer()
                        if look.wrappedValue.changesOrientation {
                            Button("Reset") { var a = look.wrappedValue; a.turns = 0; a.flipHorizontal = false; a.flipVertical = false; look.wrappedValue = a }
                                .controlSize(.small)
                        }
                    }
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
        // A photo with a look of its own shows it; the others show the export's.
        .onChange(of: photo, initial: true) { thisPhoto = photo.flatMap { CropPlacements.shared.adjustments(for: $0) } != nil }
        .onReceive(NotificationCenter.default.publisher(for: CropPlacements.changed)) { _ in placements += 1 }
    }

    /// "All photos | This photo": whose light, colour and detail the sliders set.
    @ViewBuilder var scopePicker: some View {
        if photoCount > 1, let photo {
            Picker("", selection: Binding(get: { thisPhoto }, set: { setThisPhoto($0, photo) })) {
                Text("All \(photoCount) photos").tag(false)
                Text("This photo only").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Light, colour, detail and orientation for every photo of the export, or for the one shown only")
            if thisPhoto {
                Text("This photo keeps its own look, whatever the export's.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func setThisPhoto(_ on: Bool, _ photo: URL) {
        if on {
            // Starts from the export's look, so the sliders go on from where they are.
            var a = recipe.look
            if a.isEmpty { a.exposure = 0 }
            CropPlacements.shared.set(adjustments: a.isEmpty ? Adjustments() : a, for: photo)
            if CropPlacements.shared.adjustments(for: photo) == nil { ownLook = Adjustments() }
        } else {
            CropPlacements.shared.set(adjustments: nil, for: photo)
            ownLook = nil
        }
        thisPhoto = on
    }

    /// The shown photo's own look while it has one that is still empty (so the sliders can start from zero).
    @State private var ownLook: Adjustments?

    /// The look being edited: the shown photo's own, or the export's.
    var look: Binding<Adjustments> {
        _ = placements
        if thisPhoto, let photo {
            return Binding(get: { CropPlacements.shared.adjustments(for: photo) ?? ownLook ?? recipe.look },
                           set: { ownLook = $0; CropPlacements.shared.set(adjustments: $0, for: photo) })
        }
        return Binding(get: { recipe.look }, set: { recipe.look = $0 })
    }

    func turn(_ by: Int) {
        var a = look.wrappedValue
        a.turns = ((a.turns + by) % 4 + 4) % 4
        look.wrappedValue = a
    }

    /// Ready-made and saved looks, saving the sliders as one, copying a look from photo to photo, and back to none.
    var looksMenu: some View {
        Menu {
            Section("Looks") { ForEach(Look.all) { l in Button(l.name) { apply(l) } } }
            if !userLooks.looks.isEmpty {
                Section("My Looks") { ForEach(userLooks.looks) { l in Button(l.name) { apply(l.look) } } }
            }
            Divider()
            Button("Save Current Look…") { lookName = ""; savingLook = true }.disabled(!look.wrappedValue.changesPixels)
            if !userLooks.looks.isEmpty {
                Menu("Delete Look") { ForEach(userLooks.looks) { l in Button(l.name) { userLooks.delete(l.id) } } }
            }
            Divider()
            Button("Copy Look") { UserLooks.clipboard = look.wrappedValue }.disabled(!look.wrappedValue.changesPixels)
            Button("Paste Look") { if let c = UserLooks.clipboard { look.wrappedValue = look.wrappedValue.orientationOnly.withLook(of: c) } }
                .disabled(UserLooks.clipboard == nil)
            Divider()
            Button("Reset Light, Colour & Detail") { look.wrappedValue = look.wrappedValue.orientationOnly }
                .disabled(!look.wrappedValue.changesPixels)
        } label: {
            Label("Looks", systemImage: "wand.and.stars")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("A starting point: the sliders can be tuned from it. Save your own, or copy a look onto another photo")
        .alert("Save Look", isPresented: $savingLook) {
            TextField("Name", text: $lookName, prompt: Text("e.g. Gala warm"))
            Button("Save") { userLooks.save(Look(name: lookName.isEmpty ? "Look \(userLooks.looks.count + 1)" : lookName, autoTone: recipe.autoTone, adjustments: look.wrappedValue)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The light, colour, detail, tone curve and HSL sliders as they are now, to pick from Looks in every editing screen.")
        }
    }

    func apply(_ l: Look) {
        look.wrappedValue = look.wrappedValue.orientationOnly.withLook(of: l.adjustments)
        if l.autoTone { recipe.autoTone = true }
    }
}

/// Looks saved by the user, kept in UserDefaults like watermark presets.
@MainActor
final class UserLooks: ObservableObject {
    static let shared = UserLooks()
    struct Saved: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var autoTone = false
        var adjustments: Adjustments
        var look: Look { Look(name: name, autoTone: autoTone, adjustments: adjustments) }
    }
    @Published private(set) var looks: [Saved] = []
    /// The look copied with "Copy Look", for "Paste Look" on another photo.
    static var clipboard: Adjustments?

    init() {
        looks = UserDefaults.standard.data(forKey: "looks").flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
    }

    func save(_ l: Look) {
        if let i = looks.firstIndex(where: { $0.name == l.name }) { looks[i].adjustments = l.adjustments; looks[i].autoTone = l.autoTone }
        else { looks.append(Saved(name: l.name, autoTone: l.autoTone, adjustments: l.adjustments)) }
        persist()
    }

    func delete(_ id: String) {
        looks.removeAll { $0.id == id }
        persist()
    }

    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(looks), forKey: "looks") }
}

/// The tone curve: five points at 0, ¼, ½, ¾ and 1 of the input, dragged up or down. Double-click one to put it
/// back on the line.
struct CurveEditor: View {
    @Binding var points: [Double]
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pt: (Int) -> CGPoint = { i in CGPoint(x: w * CGFloat(i) / 4, y: h * (1 - CGFloat(points[i]))) }
            ZStack {
                // Grid, the straight line, the curve.
                Path { p in
                    for i in 1...3 {
                        p.move(to: CGPoint(x: w * CGFloat(i) / 4, y: 0)); p.addLine(to: CGPoint(x: w * CGFloat(i) / 4, y: h))
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 4)); p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 4))
                    }
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: 0)) }
                    .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in
                    // The very curve the pipeline applies.
                    for i in 0...64 {
                        let x = Double(i) / 64, y = min(1, max(0, EditPipeline.curveValue(points, x)))
                        let q = CGPoint(x: w * x, y: h * (1 - y))
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                .stroke(Color.accent, lineWidth: 2)
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(Color.accent).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .position(pt(i))
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragging == nil { dragging = Int(((v.startLocation.x / w) * 4).rounded()) }
                            guard let i = dragging, (0...4).contains(i) else { return }
                            var p = points
                            p[i] = min(1, max(0, Double(1 - v.location.y / h)))
                            points = p
                        }
                        .onEnded { _ in dragging = nil })
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                        let i = Int(((v.location.x / w) * 4).rounded())
                        guard (0...4).contains(i) else { return }
                        var p = points
                        p[i] = Adjustments.straightCurve[i]
                        points = p
                    })
            }
        }
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .help("Drag a point up to brighten those tones, down to darken them: shadows on the left, highlights on the right. Double-click a point to put it back")
    }
}

/// Hue, saturation or luminance for each of eight colours.
struct HSLControls: View {
    @Binding var hsl: HSLAdjust
    @AppStorage("edit.hslTab") private var tab = 1

    static let swatches: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $tab) {
                Text("Hue").tag(0)
                Text("Saturation").tag(1)
                Text("Luminance").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            ForEach(0..<8, id: \.self) { i in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Self.swatches[i]).frame(width: 9, height: 9)
                        Text(HSLAdjust.names[i])
                    }
                    .frame(width: 84, alignment: .leading)
                    .onTapGesture(count: 2) { value(i).wrappedValue = 0 }
                    Slider(value: value(i), in: -1...1).controlSize(.small)
                    let v = value(i).wrappedValue
                    Text(v == 0 ? "0" : String(format: "%+.0f", v * 100)).monospacedDigit().font(.caption)
                        .foregroundStyle(v == 0 ? .tertiary : .secondary).frame(width: 44, alignment: .trailing)
                }
            }
        }
        .help("Hue turns a colour towards its neighbours, Saturation makes it stronger or weaker, Luminance lighter or darker. Greys are left alone. Double-click a name to reset")
    }

    func value(_ i: Int) -> Binding<Double> {
        Binding(get: {
            switch tab { case 0: hsl.hue[i]; case 1: hsl.saturation[i]; default: hsl.luminance[i] }
        }, set: { v in
            switch tab { case 0: hsl.hue[i] = v; case 1: hsl.saturation[i] = v; default: hsl.luminance[i] = v }
        })
    }
}

/// A named set of adjustments.
struct Look: Identifiable {
    let name: String
    var autoTone = false
    let adjustments: Adjustments
    var id: String { name }

    static let all: [Look] = [
        Look(name: "Natural", autoTone: true, adjustments: { var a = Adjustments(); a.vibrance = 0.15; a.clarity = 0.1; return a }()),
        Look(name: "Vivid", adjustments: { var a = Adjustments(); a.contrast = 0.25; a.vibrance = 0.45; a.clarity = 0.3; a.sharpness = 0.2; return a }()),
        Look(name: "Soft", adjustments: { var a = Adjustments(); a.contrast = -0.15; a.highlights = -0.35; a.shadows = 0.25; a.saturation = -0.1; return a }()),
        Look(name: "Warm", adjustments: { var a = Adjustments(); a.temperature = 0.3; a.vibrance = 0.15; a.shadows = 0.1; return a }()),
        Look(name: "Cool", adjustments: { var a = Adjustments(); a.temperature = -0.3; a.contrast = 0.1; return a }()),
        Look(name: "Black & White", adjustments: { var a = Adjustments(); a.monochrome = true; a.contrast = 0.3; a.clarity = 0.35; return a }()),
        Look(name: "Stage", adjustments: { var a = Adjustments(); a.exposure = 0.3; a.shadows = 0.4; a.highlights = -0.4; a.vibrance = 0.3; a.vignette = 0.25; return a }()),
    ]
}

/// A slider centred on zero (or from zero), with its value; double-click the label to put it back to zero.
struct AdjustSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var unit = ""
    var help: String? = nil

    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double> = -1...1, unit: String = "", help: String? = nil) {
        self.label = label
        _value = value
        self.range = range
        self.unit = unit
        self.help = help
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 84, alignment: .leading)
                .onTapGesture(count: 2) { value = 0 }
                .help(help ?? "Double-click the name to reset")
            Slider(value: $value, in: range).controlSize(.small)
            Text(text).monospacedDigit().font(.caption).foregroundStyle(value == 0 ? .tertiary : .secondary).frame(width: 44, alignment: .trailing)
        }
    }

    var text: String {
        if value == 0 { return "0" }
        return unit.isEmpty ? String(format: "%+.0f", value * 100) : String(format: "%+.1f%@", value, unit)
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
                    Text("px per \(Int(WatermarkSpec.bannerReferenceSide)) px").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Same height on every photo (long side). Centred, sides trimmed to the photo's width: make it wider than any photo, content in the middle. Portrait photos get the portrait banner.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Position", selection: Binding(get: { [.top, .center, .bottom][WatermarkSpec.Position.allCases.firstIndex(of: spec.position)! / 3] },
                                                      set: { spec.position = $0 })) {
                    Text("Top").tag(WatermarkSpec.Position.top)
                    Text("Middle").tag(WatermarkSpec.Position.center)
                    Text("Bottom").tag(WatermarkSpec.Position.bottom)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    CompactSlider(label: "Opacity", value: $spec.opacity, range: 0.15...1)
                    CompactSlider(label: "Margin", value: $spec.margin, range: 0...0.12)
                }
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
                .frame(width: 190)
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                if let binding = draftBinding {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: binding.name).textFieldStyle(.roundedBorder).font(.headline)
                        HStack(alignment: .top, spacing: 14) {
                            EditPreview(recipe: Binding(get: { previewRecipe }, set: { r in if let w = r.watermark { draft?.spec = w } }),
                                        samples: samples, filmstrip: false, perPhotoCrop: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            // The fields column is the preview's height whatever the kind, so the pane never grows
                            // and shrinks as the kind changes.
                            ScrollView { WatermarkFields(spec: binding.spec).padding(.trailing, 4) }
                                .frame(width: 264)
                                .frame(maxHeight: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView("No watermark presets", systemImage: "seal",
                                           description: Text("Add a logo, a text credit or a full-width banner with +. Every editing screen can use them, each with its own position and size."))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 400)
            Divider()
            HStack {
                Text("Default auto-tone strength for new screens")
                Slider(value: $strength, in: 0.2...1).frame(width: 180)
                Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 40)
            }
            Text("Each editing screen (Edit & Export, Copy/Move, delivery rules, web gallery, video stills) remembers its own crop, size and watermark.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 860)
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
