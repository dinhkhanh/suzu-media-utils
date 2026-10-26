import AppKit
import FaceLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Find people by a photo: drop one, paste one (⌘V) or choose one; each face in it lists the people it looks most
/// like, and a click opens that person. The photo is only looked at, never added to the library.
struct PhotoLookupSheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    /// Opens a person's page (the sheet closes first).
    let open: (Int64) -> Void
    @State private var url: URL?
    @State private var image: NSImage?
    @State private var result: PhotoLookup?
    @State private var looking = false
    @State private var error: String?
    @State private var face = 0
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find People by Photo").font(.title2.bold())
                Spacer()
                Button("Paste") { paste() }.keyboardShortcut("v")
                Button("Choose Photo…") { choose() }
            }
            Group {
                if let image { content(image) } else { dropZone }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { drop($0) }
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 560)
    }

    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(dropping ? Color.accent : Color.secondary.opacity(0.4))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "person.fill.viewfinder").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Drop a photo here, paste one (⌘V), or choose one").foregroundStyle(.secondary)
                    Text("Every face in it is matched against the people in the library.").font(.callout).foregroundStyle(.tertiary)
                }
            }
    }

    @ViewBuilder
    func content(_ image: NSImage) -> some View {
        HStack(alignment: .top, spacing: 18) {
            photo(image).frame(width: 300)
            VStack(alignment: .leading, spacing: 12) {
                if looking {
                    HStack { ProgressView().controlSize(.small); Text("Looking for faces…").foregroundStyle(.secondary) }
                } else if let result {
                    if result.faces.isEmpty {
                        ContentUnavailableView("No faces in this photo", systemImage: "person.slash",
                                               description: Text("Try a photo where the face is bigger or turned more towards the camera."))
                    } else {
                        if result.faces.count > 1 { facePicker(result) }
                        matches(result.faces[min(face, result.faces.count - 1)])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The photo with its faces outlined; the face being matched stands out, a click on another picks it.
    func photo(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    ForEach(result?.faces ?? []) { f in
                        let r = CGRect(x: f.box.minX * g.size.width, y: f.box.minY * g.size.height,
                                       width: f.box.width * g.size.width, height: f.box.height * g.size.height)
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(f.id == face ? Color.accent : Color.white.opacity(0.7), lineWidth: f.id == face ? 3 : 1.5)
                            .frame(width: r.width, height: r.height)
                            .contentShape(Rectangle())
                            .onTapGesture { face = f.id }
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func facePicker(_ result: PhotoLookup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(result.faces) { f in
                    Group {
                        if let p = f.preview { Image(decorative: p, scale: 1).resizable() } else { Image(systemName: "person.crop.square").resizable().padding(10) }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(f.id == face ? Color.accent : .clear, lineWidth: 3))
                    .onTapGesture { face = f.id }
                    .help(f.matches.first.map { "Looks most like \($0.name ?? "an unnamed person")" } ?? "Not readable")
                }
            }
            .padding(2)
        }
    }

    @ViewBuilder
    func matches(_ f: PhotoLookup.Face) -> some View {
        if f.matches.isEmpty {
            Text("This face can't be read well enough to match (too small, or turned away).").foregroundStyle(.secondary)
        } else {
            Text(f.matches[0].likely ? "Looks like \(f.matches[0].name ?? "this person"); also close:" : "Nobody in the library is a sure match. Closest:")
                .font(.headline)
            if (f.quality ?? 1) < 0.3 {
                Text("A blurred or half-turned face: matches are less reliable.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                    ForEach(f.matches) { m in tile(m) }
                }
            }
        }
    }

    func tile(_ m: PhotoLookup.Match) -> some View {
        Button {
            dismiss()
            open(m.personId)
        } label: {
            VStack(spacing: 4) {
                FaceImage(faceId: m.coverFaceId, side: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(m.name ?? "Unnamed").font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if m.likely {
                        Text("Likely").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accent.opacity(0.18)))
                    }
                    Text("\(Int((m.similarity * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .opacity(m.likely ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .help("\(m.faces) faces · open \(m.name ?? "this person")")
    }

    // MARK: - Getting the photo

    func choose() {
        Panels.choose(folders: false, files: true, types: [.image], prompt: "Find People") { if let u = $0.first { look(at: u) } }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let u = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            look(at: u)
        } else if let img = NSImage(pasteboard: pb) {
            look(at: img)
        } else {
            error = "There is no photo on the clipboard."
        }
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { Task { @MainActor in look(at: u) } }
            }
            return true
        }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                if let img = img as? NSImage { Task { @MainActor in look(at: img) } }
            }
            return true
        }
        return false
    }

    /// An image from the clipboard or a browser: written to a temporary file, read like any other.
    func look(at img: NSImage) {
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            error = "That image can't be read."
            return
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("photo-lookup-\(UUID().uuidString).png")
        do { try png.write(to: u) } catch { self.error = error.localizedDescription; return }
        look(at: u)
    }

    func look(at u: URL) {
        guard let service = model.service else { return }
        url = u
        image = NSImage(contentsOf: u)
        result = nil
        error = image == nil ? "That file isn't a photo this Mac can read." : nil
        face = 0
        guard image != nil else { return }
        looking = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try service.lookUpPeople(in: u) } }.value
            if u.lastPathComponent.hasPrefix("photo-lookup-") { try? FileManager.default.removeItem(at: u) }
            guard url == u else { return }  // another photo came meanwhile
            looking = false
            switch r {
            case .success(let found): result = found
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}
