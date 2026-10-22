import AppKit
import CoreImage
import FaceCore
import ImageIO
import MediaKit
import SwiftUI

/// Decoded preview photos (about 1600 px), so switching edits or flipping between a few photos is instant.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    static let context = CIContext(options: [.cacheIntermediates: false])

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

    func entry(_ url: URL) -> Entry? {
        if let e = lock.withLock({ entries[url.path] }) { return e }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var w = Double(p?[kCGImagePropertyPixelWidth] as? Int ?? cg.width), h = Double(p?[kCGImagePropertyPixelHeight] as? Int ?? cg.height)
        if let o = p?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let e = Entry(image: cg, pixelSize: CGSize(width: w, height: h))
        store(url.path, e)
        return e
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
        /// Where the crop sits (normalized, top-left origin) and the whole photo, for dragging the photo under it.
        var crop: CGRect?
        var full: NSImage?
        /// Full-size pixel dimensions, upright.
        var pixelSize: CGSize
        /// The turn applied (degrees counter-clockwise), when straightened.
        var angle: Double?
        /// The turn straightening would make on its own (degrees counter-clockwise).
        var autoAngle: Double?
    }

    /// The photo through the recipe (or untouched), plus the size the exported file will have. The photo's own crop
    /// (edited by hand) wins over the recipe's, as in the export.
    func render(_ item: ToolItem, recipe: EditRecipe, original: Bool) -> Rendered? {
        guard let e = entry(item.url) else { return nil }
        let recipe = CropPlacements.shared.recipe(recipe, for: item.url)
        var r = recipe
        r.maxLongSide = nil
        var warning: String?
        let input = CIImage(cgImage: e.image)
        var out = input, level = input
        var crop: CGRect?, angle: Double?
        let autoAngle = r.straighten == true || r.rotation != nil ? tilt(item.url).map { -$0 } : nil
        if !original {
            // Levelled first, as in the export: the crop, and the photo dragged under it, are of the levelled photo.
            let placed = CropPlacements.shared.center(for: item.url)
            var faces = r.aspect(for: input.extent.size) != nil && placed == nil ? self.focus(item.url, given: item.focus) : nil
            if let a = r.rotation ?? (r.straighten == true ? autoAngle : nil), abs(a) >= 0.01 {
                angle = a
                (level, faces) = EditPipeline.rotate(input, degrees: a, focus: faces)
            }
            r.straighten = nil
            r.rotation = nil
            var focus: FocusHint?
            if let a = r.aspect(for: level.extent.size) {
                // A crop placed by hand needs no faces.
                focus = placed.map { FocusHint(primary: nil, center: $0) } ?? faces
                let size = level.extent.size, c = EditPipeline.cropRect(imageSize: size, ratio: a.ratio, focus: focus)
                crop = CGRect(x: c.minX / size.width, y: c.minY / size.height, width: c.width / size.width, height: c.height / size.height)
            }
            do { out = try EditPipeline.apply(r, to: level, focus: focus) } catch {
                warning = "The watermark logo can't be read: choose it again"
                r.watermark = nil
                out = (try? EditPipeline.apply(r, to: level, focus: focus)) ?? level
            }
        }
        guard let cg = Self.context.createCGImage(out, from: out.extent) else { return nil }
        var full: NSImage?
        if crop != nil {
            if angle == nil { full = NSImage(cgImage: e.image, size: .zero) }
            else if let l = Self.context.createCGImage(level, from: level.extent) { full = NSImage(cgImage: l, size: .zero) }
        }
        return Rendered(image: NSImage(cgImage: cg, size: .zero), outputSize: Self.outputSize(e.pixelSize, recipe: recipe, angle: angle), warning: warning,
                        crop: crop, full: full, pixelSize: e.pixelSize, angle: angle, autoAngle: autoAngle)
    }

    static func outputSize(_ size: CGSize, recipe: EditRecipe, angle: Double? = nil) -> CGSize {
        var w = size.width, h = size.height
        if let angle { let k = EditPipeline.rotatedScale(size, degrees: angle); w *= k; h *= k }
        if let a = recipe.aspect(for: size) { let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio); w = cw; h = ch }
        if let long = recipe.maxLongSide, Double(long) < max(w, h) {
            let s = Double(long) / max(w, h); w *= s; h *= s
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// The big preview of an edit: the selected photo as it will be exported, a film strip to pick another photo, a
/// before/after switch, click-to-place for the watermark, and each photo's own crop (dragged into place, own shape).
struct EditPreview: View {
    @Binding var recipe: EditRecipe
    let samples: [ToolItem]
    var filmstrip = true
    /// Offers each photo its own crop shape and drag-to-place.
    var perPhotoCrop = true
    /// When set, photos can be ticked off: the action then applies only to the ticked ones (this set holds the
    /// unticked ones, so photos added later start ticked).
    var excluded: Binding<Set<ToolItem>>? = nil
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
    /// How far the photo has been dragged under the crop, while dragging.
    @State private var drag: CGSize?
    /// Bumped when a photo's crop is edited or reset, to render again.
    @State private var placements = 0
    /// The current photo's latest export, for the info bar.
    @State private var lastExport: ExportHistory.Record?
    @State private var exports = 0

    var current: ToolItem? { samples.isEmpty ? nil : samples[min(index, samples.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            if showGrid { grid } else { previewArea }
            if excluded != nil && samples.count > 1 { selectionBar }
            if filmstrip && samples.count > 1 && !showGrid { strip }
        }
        .onChange(of: samples.count) { if index >= samples.count { index = 0 } }
        .onChange(of: samples.count > 1) { if samples.count > 1, ProcessInfo.processInfo.environment["SUZU_TOOL_SAMPLES"] == "grid" { gridMode = true } }
        .task(id: "\(recipe.hashValue)|\(current?.url.path ?? "")|\(showOriginal)|\(placements)") { await render() }
        .task(id: "\(current?.url.path ?? "")|\(exports)") {
            guard let url = current?.url else { lastExport = nil; return }
            lastExport = await Task.detached { ExportHistory.shared.exports(of: url).first }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: CropPlacements.changed)) { _ in placements += 1 }
        .onReceive(NotificationCenter.default.publisher(for: ExportHistory.changed)) { _ in exports += 1 }
    }

    var previewArea: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.13, alpha: 1))
            if let rendered {
                Image(nsImage: rendered.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .overlay { placementLayer }
                    .padding(18)
            } else if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                    Text("Add photos or people to preview the edit").font(.callout)
                }
                .foregroundStyle(.white.opacity(0.45))
            }
            if rendering { ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12) }
        }
        .overlay(alignment: .topLeading) {
            if perPhotoCrop && !showOriginal, let current, let r = rendered {
                HStack(spacing: 0) {
                    cropMenu(current, r)
                    LevelButton(url: current.url, rendered: r, straighten: recipe.straighten == true)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Picker("", selection: $showOriginal) {
                Text("Edited").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(10)
            .help("Compare with the original photo")
        }
        .overlay(alignment: .bottom) { infoBar }
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// Thirds overlay while hovering with a watermark on; a click puts the watermark in that ninth. With a crop,
    /// dragging moves the photo under it (the whole photo shows, dimmed outside the crop, while dragging).
    @ViewBuilder
    var placementLayer: some View {
        if (recipe.watermark != nil || (perPhotoCrop && rendered?.crop != nil)) && !showOriginal {
            GeometryReader { g in
                ZStack {
                    if let t = drag, let r = rendered, let n = r.crop, let full = r.full { dragView(full, crop: n, moved: moved(n, by: t, in: g.size), size: g.size) }
                    if hovering && drag == nil && recipe.watermark != nil {
                        Path { p in
                            for i in 1...2 {
                                let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                            }
                        }
                        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { loc in
                            guard recipe.watermark != nil else { return }
                            let col = min(2, max(0, Int(loc.x / (g.size.width / 3)))), row = min(2, max(0, Int(loc.y / (g.size.height / 3))))
                            recipe.watermark?.position = WatermarkSpec.Position.allCases[row * 3 + col]
                        }
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { if perPhotoCrop && rendered?.crop != nil { drag = $0.translation } }
                            .onEnded { v in
                                if perPhotoCrop, let n = rendered?.crop, let item = current {
                                    let m = moved(n, by: v.translation, in: g.size)
                                    CropPlacements.shared.set(CGPoint(x: m.midX, y: m.midY), for: item.url)
                                    // Stays on screen until the new crop is rendered.
                                    drag = v.translation
                                } else { drag = nil }
                            })
                }
            }
            .onHover { hovering = $0 }
            .help(rendered?.crop == nil ? "Click where the watermark should go"
                  : recipe.watermark == nil ? "Drag the photo to move the crop" : "Drag the photo to move the crop; click where the watermark should go")
        }
    }

    /// This photo's crop shape: the export's (for its orientation), or its own.
    func cropMenu(_ item: ToolItem, _ r: PreviewCache.Rendered) -> some View {
        let own = CropPlacements.shared.shape(for: item.url)
        let shared = recipe.aspect(for: r.pixelSize)?.rawValue ?? "Original"
        return Menu {
            Picker("", selection: Binding(get: { own }, set: { CropPlacements.shared.set(shape: $0, for: item.url) })) {
                Text("Same as the others (\(shared))").tag(CropShape?.none)
                Divider()
                Text("Original").tag(CropShape?.some(.original))
                ForEach(AspectPreset.allCases) { a in Text(a.label).tag(CropShape?.some(.preset(a))) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(own.map { "This photo: \($0.label)" } ?? "Crop: \(shared)", systemImage: "crop")
        }
        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
        .font(.caption)
        .foregroundStyle(own == nil ? .white.opacity(0.85) : Color.accentColor)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .help("This photo's crop shape. Drag the photo to move the crop.")
    }

    /// The crop after dragging the photo by `t` in a preview `size` points big: the photo moves, so the crop moves the
    /// other way, and never past the photo's edges.
    func moved(_ n: CGRect, by t: CGSize, in size: CGSize) -> CGRect {
        var r = n
        r.origin.x = min(max(n.minX - t.width * n.width / size.width, 0), 1 - n.width)
        r.origin.y = min(max(n.minY - t.height * n.height / size.height, 0), 1 - n.height)
        return r
    }

    /// The whole photo at the preview's scale, placed under the crop as dragged: bright inside the crop, dimmed outside.
    func dragView(_ full: NSImage, crop n: CGRect, moved m: CGRect, size: CGSize) -> some View {
        let w = size.width / n.width, h = size.height / n.height
        let photo = Image(nsImage: full).resizable().frame(width: w, height: h).offset(x: -m.minX * w, y: -m.minY * h)
        return ZStack(alignment: .topLeading) {
            Color(nsColor: NSColor(white: 0.13, alpha: 1)).frame(width: size.width, height: size.height)
            photo.opacity(0.35)
            photo.frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
            Rectangle().strokeBorder(.white.opacity(0.85), lineWidth: 1).frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    var infoBar: some View {
        HStack(spacing: 10) {
            if samples.count > 1 {
                Button { index = (index - 1 + samples.count) % samples.count } label: { Image(systemName: "chevron.left") }
                Text("\(min(index, samples.count - 1) + 1) of \(samples.count)").monospacedDigit()
                Button { index = (index + 1) % samples.count } label: { Image(systemName: "chevron.right") }
            }
            if let current { Text(current.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
            if let s = rendered?.outputSize, !showOriginal { Text("→ \(Int(s.width)) × \(Int(s.height)) px \(recipe.outputFormat.label)").monospacedDigit() }
            if let w = rendered?.warning { Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            if let current, rendered?.crop != nil, !showOriginal, CropPlacements.shared.center(for: current.url) != nil {
                Button { CropPlacements.shared.set(nil, for: current.url) } label: { Label("Reset crop", systemImage: "arrow.uturn.backward") }
                    .help("This crop was placed by hand: go back to the automatic one, which keeps the people in frame")
            }
            if let e = lastExport {
                Label("Exported \(e.date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Latest export: \(e.path)")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
        .opacity(samples.isEmpty ? 0 : 1)
    }

    var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    // Long lists only show their start; the arrows still step through all of them.
                    ForEach(Array(samples.prefix(300).enumerated()), id: \.offset) { i, item in
                        // Click previews; the circle (or ⌘-click) ticks or unticks; ⇧-click ticks a range.
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), onCheck: { tick(i) }, onTap: {
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.shift) || mods.contains(.command) { tick(i) } else { clickedInStrip = true; index = i }
                        })
                        .id(i)
                        .help(item.url.lastPathComponent)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: 112)
            .background(Color(nsColor: NSColor(white: 0.09, alpha: 1)))
            .environment(\.colorScheme, .dark)
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

    /// Every photo, bigger: click to tick or untick (⇧-click for a range), double-click to preview it large.
    var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { i, item in
                        StripThumb(url: item.url, selected: i == index, checked: isChecked(item), side: 150,
                                   onCheck: { tick(i) }, onTap: { tick(i) }, onDoubleTap: { index = i; gridMode = false })
                            .id(i)
                            .help("\(item.url.lastPathComponent)\(item.personName.map { " · \($0)" } ?? "")")
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
        .environment(\.colorScheme, .dark)
    }

    func render() async {
        guard let item = current else { rendered = nil; return }
        // Let sliders settle; a newer change cancels this one.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        rendering = true
        let recipe = recipe, original = showOriginal
        let result = await Task.detached(priority: .userInitiated) { PreviewCache.shared.render(item, recipe: recipe, original: original) }.value
        guard !Task.isCancelled else { return }
        rendering = false
        if let result { rendered = result }
        drag = nil
    }
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
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
        .overlay(alignment: .topTrailing) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: side > 120 ? 22 : 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, checked ? Color.accentColor : Color.black.opacity(hoveringCheck ? 0.6 : 0.35))
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
/// automatic, or not turned at all.
struct LevelButton: View {
    let url: URL
    let rendered: PreviewCache.Rendered
    /// The export straightens tilted photos.
    let straighten: Bool
    @State private var open = false
    @State private var value = 0.0

    /// Shown clockwise, as most editors do: turning a photo that leans left back to level is a positive turn.
    var own: Double? { CropPlacements.shared.rotation(for: url) }

    var title: String {
        guard let a = rendered.angle else { return own == nil ? "Level" : "Level: none" }
        return String(format: "Level %+.1f°", -a)
    }

    var body: some View {
        Button { value = -(own ?? rendered.angle ?? 0); open = true } label: { Label(title, systemImage: "level") }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(own == nil ? .white.opacity(0.85) : Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.vertical, 10)
            .help("Turn this photo to level it")
            .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Level this photo").font(.headline)
            HStack {
                Button { nudge(-0.1) } label: { Image(systemName: "rotate.left") }.help("0.1° anticlockwise")
                Slider(value: Binding(get: { value }, set: { value = $0; save() }), in: -10...10)
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
