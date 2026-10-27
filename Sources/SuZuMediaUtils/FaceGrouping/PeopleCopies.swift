import FaceLibrary
import SwiftUI

/// A copy or move to people's folders running in the background: the dialog closes when it starts, and its
/// progress, Stop and outcome sit above the status pill.
final class PeopleCopyJob: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    /// "“An”", or "everyone's folders".
    let target: String
    let mode: ExportMode
    let total: Int
    /// What Show in Finder opens.
    let folder: URL?
    @Published var started = false
    @Published var done = 0
    @Published var stopping = false
    @Published var result: Exporter.Result?
    /// Read by the copy on its own threads, set by Stop.
    private let lock = NSLock()
    private var stopFlag = false
    var stopRequested: Bool { lock.withLock { stopFlag } }

    init(target: String, mode: ExportMode, total: Int, folder: URL?) {
        self.target = target
        self.mode = mode
        self.total = total
        self.folder = folder
    }

    /// The files under way finish, no new one starts; a job still waiting never starts.
    func stop() {
        lock.withLock { stopFlag = true }
        stopping = true
    }
}

/// Copies and moves to people's folders, one after another (two at once would only share the disk and the
/// network, and two moves could pull at the same files).
@MainActor
final class PeopleCopies: ObservableObject {
    @Published var jobs: [PeopleCopyJob] = []
    private var last: Task<Void, Never>?
    /// Where finished jobs are noted (the activity list).
    weak var model: FaceGroupingModel?

    func start(_ plan: Exporter.Plan, exporter: Exporter, policy: CollisionPolicy, workers: Int, target: String, mode: ExportMode, folder: URL?) {
        let job = PeopleCopyJob(target: target, mode: mode, total: plan.items.count, folder: folder)
        jobs.append(job)
        let previous = last
        last = Task {
            await previous?.value
            job.started = true
            ToolWork.begin()
            let total = plan.items.count
            let r = await Task.detached(priority: .utility) {
                exporter.run(plan, policy: policy, workers: workers, isCancelled: { job.stopRequested }) { n in
                    if n % 5 == 0 || n == total { Task { @MainActor in job.done = n } }
                }
            }.value
            ToolWork.end()
            job.done = total - r.notStarted
            job.result = r
            model?.log(Self.summary(job, r), icon: r.failed.isEmpty ? "folder.badge.person.crop" : "exclamationmark.triangle")
        }
    }

    func remove(_ job: PeopleCopyJob) { jobs.removeAll { $0.id == job.id } }

    static func summary(_ job: PeopleCopyJob, _ r: Exporter.Result) -> String {
        let verb = job.mode == .copy ? "copied" : "moved"
        var s = r.cancelled ? "Stopped: \(r.done) files \(verb) to \(job.target), \(r.notStarted) not \(verb)" : "\(r.done) files \(verb) to \(job.target)"
        if r.skippedExisting > 0 { s += ", \(r.skippedExisting) already there" }
        if !r.failed.isEmpty { s += ", \(r.failed.count) failed" }
        return s
    }
}

/// The background copies, above the status pill.
struct PeopleCopiesView: View {
    @ObservedObject var jobs: PeopleCopies

    var body: some View {
        if !jobs.jobs.isEmpty {
            VStack(spacing: 6) {
                ForEach(jobs.jobs) { PeopleCopyRow(job: $0, jobs: jobs) }
            }
            .padding(.horizontal, 10)
        }
    }
}

struct PeopleCopyRow: View {
    @ObservedObject var job: PeopleCopyJob
    let jobs: PeopleCopies

    var verb: String { job.mode == .copy ? "Copying" : "Moving" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: job.result == nil ? "doc.on.doc" : job.result!.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(job.result == nil ? AnyShapeStyle(.secondary) : job.result!.failed.isEmpty ? AnyShapeStyle(Color.good) : AnyShapeStyle(Color.notice))
                Text(job.result == nil ? "\(verb) to \(job.target)" : job.result!.cancelled ? "Stopped \(verb.lowercased()) to \(job.target)" : "Done: \(job.target)")
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if job.result == nil {
                    Button("Stop") { job.stop() }.controlSize(.small).disabled(job.stopping)
                        .help("Files being copied finish; no new one starts. Run it again later to do the rest.")
                } else {
                    Button { jobs.remove(job) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
                }
            }
            if let r = job.result {
                Text(PeopleCopies.summary(job, r) + (r.cancelled ? ". Run it again to do the rest: files already there are skipped." : "."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(r.failed.prefix(3).enumerated()), id: \.offset) { _, f in
                    Text("\(f.0): \(f.1)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let folder = job.folder {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.controlSize(.small)
                }
            } else {
                ProgressView(value: Double(job.done), total: Double(max(1, job.total))).progressViewStyle(.linear).controlSize(.small)
                Text(job.stopping ? "Stopping after the files under way…" : job.started ? "\(job.done.formatted()) of \(job.total.formatted()) files" : "Waits for the one before it")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5)))
    }
}
