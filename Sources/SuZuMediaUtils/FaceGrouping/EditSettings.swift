import FaceLibrary
import MediaKit
import SwiftUI

/// Default editing choices (logo, auto tone) shared by exports, delivery rules and the Batch Export tool.
enum EditSettings {
    static var watermark: WatermarkSpec? {
        get { UserDefaults.standard.data(forKey: "watermark").flatMap { try? JSONDecoder().decode(WatermarkSpec.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "watermark") }
    }
    static var autoToneStrength: Double {
        get { UserDefaults.standard.object(forKey: "autoToneStrength") as? Double ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "autoToneStrength") }
    }
}

/// Settings → Editing: the SuZu logo used for watermarks and the default auto-tone strength.
struct EditingSettings: View {
    @State private var spec = EditSettings.watermark ?? WatermarkSpec(logoPath: "")
    @State private var strength = EditSettings.autoToneStrength

    var body: some View {
        Form {
            Section("Watermark logo") {
                HStack {
                    Text(spec.logoPath.isEmpty ? "No logo chosen" : (spec.logoPath as NSString).lastPathComponent)
                        .foregroundStyle(spec.logoPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose Logo…") { chooseLogo() }
                }
                Picker("Position", selection: $spec.position) {
                    ForEach(WatermarkSpec.Position.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Size") { Slider(value: $spec.size, in: 0.08...0.5) }
                LabeledContent("Opacity") { Slider(value: $spec.opacity, in: 0.2...1) }
                LabeledContent("Margin") { Slider(value: $spec.margin, in: 0...0.1) }
                Text("PNG with a transparent background works best. Size is relative to the photo's shorter side, so it looks the same on portrait and landscape shots.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto tone") {
                LabeledContent("Strength") {
                    HStack { Slider(value: $strength, in: 0.2...1); Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 44) }
                }
                Text("Auto tone fixes exposure, contrast, shadows/highlights and colour balance (face-aware). Lower strength keeps more of the original look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onChange(of: spec) { EditSettings.watermark = spec.logoPath.isEmpty ? nil : spec }
        .onChange(of: strength) { EditSettings.autoToneStrength = strength }
    }

    func chooseLogo() {
        Panels.choose(folders: false, files: true, types: [.png, .jpeg, .tiff, .heic], prompt: "Use Logo") { if let u = $0.first { spec.logoPath = u.path } }
    }
}

/// The edit options shown in export dialogs, with a live preview.
struct EditOptionsView: View {
    @Binding var recipe: EditRecipe
    /// A photo to preview the edit on, and where its people are.
    var previewSource: URL?
    var previewFocus: FocusHint?
    @State private var preview: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto tone & enhance", isOn: $recipe.autoTone)
                    .help("Exposure, contrast, shadows/highlights, vibrance and skin-tone balance; on automatically with crops and watermarks")
                Picker("Crop", selection: $recipe.aspect) {
                    Text("Keep original frame").tag(AspectPreset?.none)
                    ForEach(AspectPreset.allCases) { Text($0.label).tag(AspectPreset?.some($0)) }
                }
                Toggle("Watermark with logo", isOn: Binding(get: { recipe.watermark != nil },
                                                            set: { recipe.watermark = $0 ? EditSettings.watermark : nil }))
                    .disabled(EditSettings.watermark == nil)
                    .help(EditSettings.watermark == nil ? "Choose a logo in Settings → Editing first" : "")
                Picker("Size", selection: $recipe.maxLongSide) {
                    Text("Original").tag(Int?.none)
                    if let a = recipe.aspect { Text("\(a.suggestedLongSide) px (recommended)").tag(Int?.some(a.suggestedLongSide)) }
                    ForEach([3000, 2048, 1600, 1080], id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                }
                LabeledContent("JPEG quality") { Slider(value: $recipe.jpegQuality, in: 0.6...1) }
            }
            .frame(maxWidth: .infinity)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let preview { Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit) } else { ProgressView().controlSize(.small) }
            }
            .frame(width: 170, height: 170)
        }
        .onAppear { recipe.autoToneStrength = EditSettings.autoToneStrength }
        // Photos going out with a social crop or the logo are auto-toned too (can still be switched off).
        .onChange(of: recipe.aspect) { old, new in if old == nil && new != nil { recipe.autoTone = true } }
        .onChange(of: recipe.watermark) { old, new in if old == nil && new != nil { recipe.autoTone = true } }
        .task(id: "\(recipe.hashValue)|\(previewSource?.path ?? "")") { await renderPreview() }
    }

    static let context = CIContext(options: [.cacheIntermediates: false])
    /// The decoded preview photo, reused while only the edit settings change.
    @State private var decoded: (URL, CGImage)?

    func renderPreview() async {
        guard let url = previewSource else { preview = nil; return }
        // Wait for sliders to settle; a newer change cancels this one.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let recipe = recipe, focus = previewFocus, cached = decoded?.0 == url ? decoded?.1 : nil
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, NSImage)? in
            // Preview on a small decode: same composition, a fraction of the work.
            var thumb = cached
            if thumb == nil, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 600,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }
            guard let thumb else { return nil }
            var r = recipe
            r.maxLongSide = nil
            guard let out = try? EditPipeline.apply(r, to: CIImage(cgImage: thumb), focus: focus),
                  let cg = Self.context.createCGImage(out, from: out.extent) else { return nil }
            return (thumb, NSImage(cgImage: cg, size: .zero))
        }.value
        guard !Task.isCancelled, let result else { return }
        decoded = (url, result.0)
        preview = result.1
    }
}
