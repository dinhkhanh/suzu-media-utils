import MediaKit
import SwiftUI

/// Checks a copy (memory card -> NAS, NAS -> backup) is complete and intact, and repairs it.
struct CopyVerifierTool: View {
    @State private var source: URL?
    @State private var destination: URL?
    @State private var checksums = true
    /// Whether the shown report compared contents.
    @State private var compared = true
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var report: FolderVerifier.Report?
    @State private var repairMessage: String?

    var body: some View {
        Form {
            Section("Folders") {
                FolderField(title: "Original", url: $source)
                FolderField(title: "Copy", url: $destination)
                Toggle("Compare contents (SHA-256 checksums; reads every file twice)", isOn: $checksums)
                if !checksums {
                    Text("Sizes only: a damaged file of the right size passes.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    if running { ProgressView(value: Double(progress.0), total: Double(max(1, progress.1))).frame(maxWidth: 260) }
                    Spacer()
                    Button("Verify") { verify() }.keyboardShortcut(.defaultAction).disabled(running || source == nil || destination == nil)
                }
            }
            if let r = report {
                Section(r.isComplete ? (compared ? "✓ The copy is complete and identical" : "✓ Every file is there with the right size (contents not compared)")
                                     : "Problems found") {
                    LabeledContent("Matching files", value: "\(r.matched)")
                    row("Missing from the copy", r.missing)
                    row("Incomplete (different size)", r.sizeMismatch)
                    row("Damaged (different contents)", r.contentMismatch)
                    row("Only in the copy", r.extra)
                    if !r.isComplete {
                        HStack {
                            if let repairMessage { Text(repairMessage).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Copy Missing and Replace Broken Files") { repair(r) }.disabled(running)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Copy Verifier")
        .navigationSubtitle("Is the photographer's upload complete?")
    }

    @ViewBuilder
    func row(_ title: String, _ list: [String]) -> some View {
        if !list.isEmpty {
            DisclosureGroup("\(title): \(list.count)") {
                ForEach(list.prefix(300), id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    func verify() {
        guard let source, let destination else { return }
        running = true; report = nil; repairMessage = nil
        let checksums = checksums
        compared = checksums
        ToolWork.begin()
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in ToolWork.end() } }
            let r = FolderVerifier.verify(source: source, destination: destination, checksums: checksums) { d, t in
                if d % 20 == 0 || d == t { Task { @MainActor in progress = (d, t) } }
            }
            await MainActor.run { report = r; running = false }
        }
    }

    func repair(_ r: FolderVerifier.Report) {
        guard let source, let destination else { return }
        running = true
        ToolWork.begin()
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in ToolWork.end() } }
            let (repaired, failures) = FolderVerifier.repair(r, source: source, destination: destination) { d, t in
                Task { @MainActor in progress = (d, t) }
            }
            // Each repaired file was checked as it was copied: move it from its problem list to the matches.
            var after = r
            let fixed = Set(repaired)
            after.missing.removeAll { fixed.contains($0) }
            after.sizeMismatch.removeAll { fixed.contains($0) }
            after.contentMismatch.removeAll { fixed.contains($0) }
            after.matched += repaired.count
            let updated = after
            await MainActor.run {
                repairMessage = failures.isEmpty ? "Repaired \(repaired.count) files."
                    : "\(failures.count) files could not be repaired: \(failures.first!.key): \(failures.first!.value)"
                report = updated
                running = false
            }
        }
    }
}
