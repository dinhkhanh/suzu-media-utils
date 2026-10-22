import MediaKit
import SwiftUI

/// Checks a copy (memory card -> NAS, NAS -> backup) is complete and intact, and repairs it.
struct CopyVerifierTool: View {
    @State private var source: URL?
    @State private var destination: URL?
    @State private var checksums = false
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var report: FolderVerifier.Report?
    @State private var repairMessage: String?

    var body: some View {
        Form {
            Section("Folders") {
                FolderField(title: "Original", url: $source)
                FolderField(title: "Copy", url: $destination)
                Toggle("Compare contents (SHA-256 checksums; reads every file twice, slower)", isOn: $checksums)
            }
            Section {
                HStack {
                    if running { ProgressView(value: Double(progress.0), total: Double(max(1, progress.1))).frame(maxWidth: 260) }
                    Spacer()
                    Button("Verify") { verify() }.keyboardShortcut(.defaultAction).disabled(running || source == nil || destination == nil)
                }
            }
            if let r = report {
                Section(r.isComplete ? "✓ The copy is complete" : "Problems found") {
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
        Task.detached(priority: .utility) {
            let r = FolderVerifier.verify(source: source, destination: destination, checksums: checksums) { d, t in
                if d % 20 == 0 || d == t { Task { @MainActor in progress = (d, t) } }
            }
            await MainActor.run { report = r; running = false }
        }
    }

    func repair(_ r: FolderVerifier.Report) {
        guard let source, let destination else { return }
        running = true
        Task.detached(priority: .utility) {
            let failures = FolderVerifier.repair(r, source: source, destination: destination) { d, t in
                Task { @MainActor in progress = (d, t) }
            }
            let again = FolderVerifier.verify(source: source, destination: destination, checksums: false)
            await MainActor.run {
                repairMessage = failures.isEmpty ? "Repaired." : "\(failures.count) files could not be copied."
                report = again
                running = false
            }
        }
    }
}
