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
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = ImageLoader.decode(src, maxPixel: 1600) else { return nil }
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
        let zoom = CropPlacements.shared.zoom(for: item.url)
        if !original {
            // Levelled first, as in the export: the crop, and the photo dragged under it, are of the levelled photo.
            let placed = CropPlacements.shared.center(for: item.url)
            var faces = (r.aspect(for: input.extent.size) != nil || zoom != nil) && placed == nil ? self.focus(item.url, given: item.focus) : nil
            if let a = r.rotation ?? (r.straighten == true ? autoAngle : nil), abs(a) >= 0.01 {
                angle = a
                (level, faces) = EditPipeline.rotate(input, degrees: a, focus: faces)
            }
            r.straighten = nil
            r.rotation = nil
            var focus: FocusHint?
            if let ratio = EditPipeline.cropRatio(r, size: level.extent.size, focus: FocusHint(primary: nil, zoom: zoom)) {
                // A crop placed by hand needs no faces; one only zoomed by hand is placed by the faces.
                var f = placed.map { FocusHint(primary: nil, center: $0) } ?? faces ?? FocusHint(primary: nil)
                f.zoom = zoom
                focus = f
                let size = level.extent.size, c = EditPipeline.cropRect(imageSize: size, ratio: ratio, focus: focus)
                crop = CGRect(x: c.minX / size.width, y: c.minY / size.height, width: c.width / size.width, height: c.height / size.height)
            }
            do { out = try EditPipeline.apply(r, to: level, focus: focus) } catch {
                warning = "The watermark logo can't be read: choose it again"
                r.watermark = nil
                out = (try? EditPipeline.apply(r, to: level, focus: focus)) ?? level
            }
        }
        guard let cg = Self.context.createCGImage(out, from: out.extent) else { return nil }
        // The whole (levelled) photo, for dragging and zooming the crop; a photo without a crop yet can be zoomed into one.
        var full: NSImage?
        if !original {
            if angle == nil { full = NSImage(cgImage: e.image, size: .zero) }
            else if let l = Self.context.createCGImage(level, from: level.extent) { full = NSImage(cgImage: l, size: .zero) }
        }
        return Rendered(image: NSImage(cgImage: cg, size: .zero), outputSize: Self.outputSize(e.pixelSize, recipe: recipe, angle: angle, zoom: zoom ?? 1),
                        warning: warning, crop: crop, full: full, pixelSize: e.pixelSize, angle: angle, autoAngle: autoAngle)
    }

    static func outputSize(_ size: CGSize, recipe: EditRecipe, angle: Double? = nil, zoom: Double = 1) -> CGSize {
        var w = size.width, h = size.height
        if let angle { let k = EditPipeline.rotatedScale(size, degrees: angle); w *= k; h *= k }
        if let a = recipe.aspect(for: size) { let cw = min(w, h * a.ratio), ch = min(h, w / a.ratio); w = cw; h = ch }
        if zoom > 1 { w /= zoom; h /= zoom }
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
    /// A word on some photos (why one was unticked), shown with the file name on hover.
    var notes: [ToolItem: String] = [:]
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
    /// The pinch in progress (its magnification), zooming the crop.
    @State private var pinch: Double?
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

    var current: ToolItem? { samples.isEmpty ? nil : samples[min(index, samples.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            if showGrid { grid } else { previewArea }
            if excluded != nil && samples.count > 1 { selectionBar }
            if filmstrip && samples.count > 1 && !showGrid { strip }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.upArrow) { step(showGrid ? -gridColumns : -1) }
        .onKeyPress(.downArrow) { step(showGrid ? gridColumns : 1) }
        .onKeyPress(.home) { step(-samples.count) }
        .onKeyPress(.end) { step(samples.count) }
        .onKeyPress(.space) {
            guard excluded != nil, !samples.isEmpty else { return .ignored }
            tick(min(index, samples.count - 1))
            return .handled
        }
        .onKeyPress(.return) {
            guard showGrid else { return .ignored }
            gridMode = false
            return .handled
        }
        .onAppear { if samples.count > 1 { focused = true } }
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

    /// Moves to another photo with the keyboard (no wrapping at the ends); the strip or grid scrolls to it.
    func step(_ by: Int) -> KeyPress.Result {
        guard samples.count > 1 else { return .ignored }
        let i = min(max(min(index, samples.count - 1) + by, 0), samples.count - 1)
        if i != index { index = i }
        return .handled
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
        .overlay(alignment: .top) {
            // The photo's own crop tools on the left, the before/after switch on the right; in a narrow preview the
            // switch drops to a second row instead of covering the tools.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) { cropTools; Spacer(minLength: 8); compareSwitch }
                VStack(alignment: .trailing, spacing: 0) { HStack(spacing: 0) { cropTools; Spacer(minLength: 0) }; compareSwitch }
            }
        }
        .overlay(alignment: .bottom) { infoBar }
        .clipped()
        .environment(\.colorScheme, .dark)
        .simultaneousGesture(TapGesture().onEnded { focused = true })
    }

    @ViewBuilder
    var cropTools: some View {
        if perPhotoCrop && !showOriginal, let current, let r = rendered {
            HStack(spacing: 0) {
                cropMenu(current, r)
                ZoomButton(url: current.url)
                LevelButton(url: current.url, rendered: r, straighten: recipe.straighten == true)
            }
        }
    }

    var compareSwitch: some View {
        Picker("", selection: $showOriginal) {
            Text("Edited").tag(false)
            Text("Original").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().padding(10)
        .help("Compare with the original photo")
    }

    /// Thirds overlay while hovering with a watermark on; a click puts the watermark in that ninth. With a crop,
    /// dragging moves the photo under it, and a pinch zooms the crop in or out (the whole photo shows, dimmed outside
    /// the crop, meanwhile). A pinch on a photo without a crop zooms into one of the photo's own shape.
    @ViewBuilder
    var placementLayer: some View {
        if (recipe.watermark != nil || perPhotoCrop) && !showOriginal {
            GeometryReader { g in
                ZStack {
                    if drag != nil || pinch != nil, let r = rendered, let full = r.full {
                        dragView(full, moved: adjusted(frame(r), in: g.size).rect, size: g.size)
                    }
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
                                if perPhotoCrop && rendered?.crop != nil {
                                    // Stays on screen until the new crop is rendered.
                                    drag = v.translation
                                    commit(in: g.size)
                                } else { drag = nil }
                            }
                            .simultaneously(with: MagnifyGesture(minimumScaleDelta: 0.02)
                                .onChanged { if perPhotoCrop { pinch = $0.magnification } }
                                .onEnded { v in
                                    guard perPhotoCrop else { return }
                                    pinch = v.magnification
                                    commit(in: g.size)
                                }))
                }
            }
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    var help: String {
        var parts: [String] = []
        if perPhotoCrop { parts.append(rendered?.crop == nil ? "Pinch to zoom in on part of the photo" : "Drag the photo to move the crop, pinch to zoom it") }
        if recipe.watermark != nil { parts.append("click where the watermark should go") }
        return parts.joined(separator: "; ")
    }

    /// The current crop (normalized), or the whole photo when it has none yet.
    func frame(_ r: PreviewCache.Rendered) -> CGRect { r.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    /// The crop as the gesture in progress leaves it: zoomed about its centre by the pinch (never wider than the
    /// photo, never past `CropPlacements.maxZoom`), then moved the other way to the photo's drag, kept inside the
    /// photo. `zoom` is the crop's resulting zoom.
    func adjusted(_ n: CGRect, in size: CGSize) -> (rect: CGRect, zoom: Double) {
        let current = current.flatMap { CropPlacements.shared.zoom(for: $0.url) } ?? 1
        let zoom = min(max(current * (pinch ?? 1), 1), CropPlacements.maxZoom)
        let s = current / zoom
        var r = CGRect(x: n.midX - n.width * s / 2, y: n.midY - n.height * s / 2, width: n.width * s, height: n.height * s)
        if let t = drag {
            r.origin.x -= t.width * r.width / size.width
            r.origin.y -= t.height * r.height / size.height
        }
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return (r, zoom)
    }

    /// Saves the gesture's crop as this photo's own: its zoom (after a pinch) and where it sits.
    func commit(in size: CGSize) {
        guard let item = current, let r = rendered else { return }
        let (m, zoom) = adjusted(frame(r), in: size)
        let center = CGPoint(x: m.midX, y: m.midY)
        if pinch != nil { CropPlacements.shared.set(zoom: zoom, center: center, for: item.url) }
        else { CropPlacements.shared.set(center, for: item.url) }
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
        .help("This photo's crop shape. Drag the photo to move the crop, pinch to zoom it.")
    }

    /// The whole photo at the scale that fills the preview with the crop `m` (normalized), placed under it as dragged
    /// and zoomed: bright inside the crop, dimmed outside.
    func dragView(_ full: NSImage, moved m: CGRect, size: CGSize) -> some View {
        let w = size.width / m.width, h = size.height / m.height
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
            if let current, rendered?.crop != nil, !showOriginal, let e = CropPlacements.shared.edit(for: current.url), e.center != nil || e.zoom != nil {
                Button { CropPlacements.shared.resetPlacement(for: current.url) } label: { Label("Reset crop", systemImage: "arrow.uturn.backward") }
                    .help("This crop was \(e.zoom != nil ? "zoomed and " : "")placed by hand: go back to the automatic one, which keeps the people in frame")
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
        pinch = nil
    }
}

/// This photo's crop zoom: a slider from the largest crop that fits to four times closer, so the edges of an event
/// photo can be trimmed away without changing its shape. The faces place the zoomed crop until it's dragged.
struct ZoomButton: View {
    let url: URL
    @State private var open = false
    @State private var value = 1.0

    var own: Double? { CropPlacements.shared.zoom(for: url) }
    var title: String { own.map { String(format: "Zoom %.1f×", $0) } ?? "Zoom" }

    var body: some View {
        Button { value = own ?? 1; open = true } label: { Label(title, systemImage: "plus.magnifyingglass") }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(own == nil ? .white.opacity(0.85) : Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.vertical, 10)
            .help("Zoom this photo's crop in, to trim its edges (or pinch on the photo)")
            .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zoom this photo's crop").font(.headline)
            HStack {
                Button { nudge(-0.1) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out a little")
                Slider(value: Binding(get: { value }, set: { value = $0; save() }), in: 1...CropPlacements.maxZoom)
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
