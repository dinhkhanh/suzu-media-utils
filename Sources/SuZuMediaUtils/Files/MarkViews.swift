import AppKit
import FaceLibrary
import SwiftUI

extension ColorLabel {
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
    /// Lightroom's keys: 6 red, 7 yellow, 8 green, 9 blue (purple has none).
    var key: String? {
        switch self {
        case .red: "6"
        case .yellow: "7"
        case .green: "8"
        case .blue: "9"
        case .purple: nil
        }
    }
}

extension MarkChange {
    /// Lightroom's culling keys: 0-5 stars, 6-9 colour labels, P pick, X reject, U unflag. A label key on files that
    /// all have that label already takes it off.
    static func forKey(_ event: NSEvent, current: [ProjectFile]) -> MarkChange? {
        guard let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
        if let n = Int(c), (0...5).contains(n) { return .rating(n) }
        if let label = ColorLabel.allCases.first(where: { $0.key == c }) {
            return .label(!current.isEmpty && current.allSatisfy { $0.label == label } ? nil : label)
        }
        switch c {
        case "p": return .flag(.pick)
        case "x": return .flag(.reject)
        case "u": return .flag(.none)
        default: return nil
        }
    }
}

extension FaceGroupingModel {
    /// Saves a rating, label or flag; views that show marks re-read afterwards.
    func mark(_ ids: [Int64], _ change: MarkChange) {
        guard let store, !ids.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let error = Result { try store.db.write { db in try Marks.apply(change, to: ids, db: db) } }.failure
            await MainActor.run {
                if let error { self.actionError = error.localizedDescription }
                self.marksVersion += 1
            }
        }
    }

    /// Copies ratings and labels into the photos' XMP; a short summary of what happened.
    func writeMarksToFiles(_ ids: [Int64]) async -> String {
        guard let service else { return "The library isn't open yet." }
        return await Task.detached(priority: .userInitiated) {
            do {
                let r = try service.writeMarksToFiles(ids)
                return "Wrote ratings and labels into \(r.written) photo\(r.written == 1 ? "" : "s")."
                    + (r.skipped > 0 ? " \(r.skipped) skipped (videos, RAW or files that couldn't be written)." : "")
            } catch {
                return "Couldn't write ratings: \(error.localizedDescription)"
            }
        }.value
    }
}

/// Five stars; click one to set the rating, click the current one to clear it.
struct StarsView: View {
    let rating: Int
    var size: CGFloat = 11
    var onSet: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(n <= rating ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    .onTapGesture { onSet?(n == rating ? 0 : n) }
                    .allowsHitTesting(onSet != nil)
            }
        }
        .help(onSet == nil ? "\(rating) star\(rating == 1 ? "" : "s")" : "Rating: keys 0–5")
    }
}

/// A pick's flag or a reject's cross; nothing for unflagged files.
struct FlagBadge: View {
    let flag: PickFlag
    var size: CGFloat = 11
    /// White on photos, the text colour elsewhere.
    var onImage = false

    var body: some View {
        switch flag {
        case .pick: Image(systemName: "flag.fill").font(.system(size: size)).foregroundStyle(onImage ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        case .reject: Image(systemName: "xmark.circle.fill").font(.system(size: size)).foregroundStyle(.white, .red)
        case .none: EmptyView()
        }
    }
}

/// Closed eyes or soft focus on the main face, from the best-shot analysis.
struct HintLabels: View {
    let file: ProjectFile

    var body: some View {
        if file.eyesClosed { Label("Eyes closed", systemImage: "eye.slash").foregroundStyle(.orange) }
        if file.soft { Label("Soft focus", systemImage: "camera.metering.unknown").foregroundStyle(.orange) }
    }
}

/// Rating, label and flag commands for a context menu or a toolbar menu.
struct MarkMenu: View {
    let files: [ProjectFile]
    let apply: (MarkChange) -> Void

    var body: some View {
        Menu("Rating") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? "No Rating (0)" : "\(String(repeating: "★", count: n))  (\(n))") { apply(.rating(n)) }
            }
        }
        Menu("Label") {
            ForEach(ColorLabel.allCases, id: \.self) { l in
                Button(l.key.map { "\(l.title)  (\($0))" } ?? l.title) { apply(.label(l)) }
            }
            Divider()
            Button("No Label") { apply(.label(nil)) }
        }
        Button("Pick  (P)") { apply(.flag(.pick)) }
        Button("Reject  (X)") { apply(.flag(.reject)) }
        if files.contains(where: { $0.flag != .none }) { Button("Unflag  (U)") { apply(.flag(.none)) } }
    }
}
