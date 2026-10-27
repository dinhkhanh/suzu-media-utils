import FaceLibrary
import SwiftUI

/// The start screen: the event at a glance. Four counts, the night's workflow as five steps (each a link), the
/// sessions as a timeline, what needs the user, and what happened. Everything here is a shortcut to a screen that
/// does the work; nothing is done on the Overview itself.
struct OverviewView: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Binding var route: AppRoute?
    @State private var exportAll: ExportMode?
    @State private var galleryExport = false
    @State private var cards = 0

    var named: Int { model.people.count { $0.faces > 0 && $0.name != nil } }
    var unnamed: Int { model.people.count { $0.faces > 0 && $0.name == nil } }
    var offline: [SourceSummary] { model.projectSources.filter { !$0.online } }
    var failed: Int { model.projectSources.reduce(0) { $0 + $1.failed } }
    var activeRules: [DeliveryRule] { model.rules.filter { $0.enabled && (model.currentProject == nil || $0.projectId == nil || $0.projectId == model.currentProject) } }
    var unreachableRules: [DeliveryRule] { activeRules.filter { r in r.folder.map { !FileManager.default.fileExists(atPath: $0) } ?? false } }

    var body: some View {
        Group {
            if let error = model.startupError {
                ContentUnavailableView("Face Grouping can't start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.service == nil {
                ProgressView("Opening library…")
            } else if model.projects.isEmpty {
                ContentUnavailableView {
                    Label("One project per event", systemImage: "calendar")
                } description: {
                    Text("Create a project and add this event's photo and video folders. People you name are recognised in every later project.")
                } actions: {
                    Button("New Project…") { model.askNewProject = true }.buttonStyle(.borderedProminent)
                }
            } else if model.currentProject != nil && model.projectSources.isEmpty {
                ContentUnavailableView {
                    Label("No folders yet in \(model.projectName)", systemImage: "folder")
                } description: {
                    Text("Add this event's photo and video folders (local, external drive or NAS), or copy them off the photographers' cards.")
                } actions: {
                    HStack {
                        Button("Add Folder…") { model.addFolder(kind: .media) }.buttonStyle(.borderedProminent)
                        Button("Copy from Cards") { route = .tool(.cards) }
                    }
                }
            } else {
                dashboard
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { model.addFolder(kind: .media) } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    .help("Add a photo & video folder to the project")
            }
            ToolbarItem {
                Menu {
                    Button("Copy All to Person Folders…") { exportAll = .copy }
                    Button("Move All to Person Folders…") { exportAll = .move }
                    Divider()
                    Button("Export Web Gallery…") { galleryExport = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Copy or move every named person's photos and videos into folders named after them, or share a web gallery")
            }
        }
        .sheet(item: $exportAll) { ExportSheet(scope: .all, mode: $0) }
        .sheet(isPresented: $galleryExport) { GalleryExportSheet() }
        .task {
            // Cards come and go during the night: look every few seconds (cheap: mounted volumes with a DCIM folder).
            while !Task.isCancelled {
                let n = CardCopyModel.volumes.count
                if n != cards { cards = n }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var subtitle: String {
        var parts = [model.projectName]
        if let team = model.currentTeam { parts.append("Team \(team.name)") }
        let folders = model.projectSources.count
        parts.append("\(folders) folder\(folders == 1 ? "" : "s")")
        parts.append("\(model.stats.files.formatted()) files")
        return parts.joined(separator: " · ")
    }

    var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                counts
                workflow
                if !model.sessions.isEmpty { sessions }
                HStack(alignment: .top, spacing: 16) {
                    needsYou
                    activity
                }
            }
            .padding(22)
        }
    }

    // MARK: - Counts

    var counts: some View {
        // Equal heights: each card stretches to the tallest, and the row takes only the height it needs.
        HStack(alignment: .top, spacing: 16) {
            OverviewCard(title: "Files", action: { route = .files }) {
                BigNumber(model.stats.files)
                let folders = model.projectSources.count
                let nas = model.projectSources.count { $0.network }
                Text("\(folders) folder\(folders == 1 ? "" : "s")" + (nas > 0 ? " · \(nas) on the NAS" : "")
                     + (model.stats.pending > 0 ? " · \(model.stats.pending.formatted()) \(model.processingMac.map { "waiting for \($0)" } ?? "processing")" : " · up to date"))
                    .foregroundStyle(.secondary).lineLimit(1)
                if model.stats.pending > 0 {
                    ProgressView(value: Double(model.stats.files - model.stats.pending), total: Double(max(1, model.stats.files)))
                        .controlSize(.small)
                }
            }
            OverviewCard(title: "People", action: { route = .faces(.people) }) {
                BigNumber(named + unnamed)
                HStack(spacing: 4) {
                    Text("\(named) named").foregroundStyle(.secondary)
                    if unnamed > 0 { Text("· \(unnamed) still unnamed").foregroundStyle(Color.notice) }
                }
                .lineLimit(1)
                FaceStack(faceIds: model.people.filter { $0.faces > 0 }.prefix(5).compactMap(\.coverFaceId))
            }
            OverviewCard(title: "Faces to review", action: { route = .faces(.unassigned) }) {
                BigNumber(model.stats.unassignedFaces)
                Text(model.stats.unassignedFaces == 0 ? "Everyone is assigned" : "Unassigned, in \(model.overview.unassignedPhotos.formatted()) photos")
                    .foregroundStyle(.secondary).lineLimit(1)
                if model.stats.unassignedFaces > 0 { Text("Review →").foregroundStyle(Color.notice).fontWeight(.medium) }
            }
            OverviewCard(title: "Delivered", action: { route = .faces(.rules) }) {
                BigNumber(model.overview.delivered)
                let n = activeRules.count
                Text("\(n) auto rule\(n == 1 ? "" : "s")" + (model.overview.lastDelivered.map { " · last copy \(TeamBar.ago($0))" } ?? ""))
                    .foregroundStyle(.secondary).lineLimit(1)
                if let r = unreachableRules.first {
                    Label("\(r.displayName { id in model.knownPeople.first { $0.id == id }?.displayName }) waits for its folder", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.notice).lineLimit(1)
                } else if n > 0 {
                    Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(Color.good)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Workflow

    var workflow: some View {
        OverviewCard(title: "Tonight's workflow", caption: "click a step to go there") {
            HStack(spacing: 10) {
                WorkflowStep(number: 1, title: "Ingest", icon: "sdcard", action: { route = .tool(.cards) }) {
                    if cards > 0 {
                        Text("\(cards) card\(cards == 1 ? "" : "s") connected").foregroundStyle(Color.notice)
                        Text("Copy what is new").foregroundStyle(.secondary)
                    } else {
                        Text("No card connected").foregroundStyle(.secondary)
                        Text("Insert one to copy new files").foregroundStyle(.tertiary)
                    }
                }
                WorkflowStep(number: 2, title: "Recognise", icon: "faceid", action: { route = .files }) {
                    let done = model.stats.files - model.stats.pending
                    if model.stats.pending > 0 {
                        Text("\(done.formatted()) done · \(model.stats.pending.formatted()) left").foregroundStyle(.secondary)
                        ProgressView(value: Double(done), total: Double(max(1, model.stats.files))).controlSize(.small)
                    } else {
                        Text("\(done.formatted()) files recognised").foregroundStyle(.secondary)
                        Label("Up to date", systemImage: "checkmark").foregroundStyle(Color.good)
                    }
                }
                WorkflowStep(number: 3, title: "Name", icon: "pencil", action: { route = .faces(unnamed > 0 ? .toName : .people) }) {
                    Text("\(named) of \(named + unnamed) named").foregroundStyle(.secondary)
                    if unnamed > 0 { Text("\(unnamed) to go").foregroundStyle(Color.notice) }
                    else if named > 0 { Label("Everyone named", systemImage: "checkmark").foregroundStyle(Color.good) }
                    else { Text("Groups appear as files are processed").foregroundStyle(.tertiary) }
                }
                WorkflowStep(number: 4, title: "Cull", icon: "star", action: { route = .files }) {
                    Text("\(model.overview.picks.formatted()) picks · \(model.overview.rejects.formatted()) rejects").foregroundStyle(.secondary)
                    Text("★★★+ \(model.overview.rated.formatted())").foregroundStyle(.tertiary)
                }
                WorkflowStep(number: 5, title: "Deliver", icon: "paperplane", action: { route = .faces(.rules) }) {
                    let n = activeRules.count
                    Text(n == 0 ? "No auto rules yet" : "\(n) rule\(n == 1 ? "" : "s") running").foregroundStyle(.secondary)
                    if model.overview.delivered > 0 {
                        Text("\(model.overview.delivered.formatted()) files delivered").foregroundStyle(Color.good)
                    } else {
                        Text("Copies land as photos are named").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Sessions

    var sessions: some View {
        let first = model.sessions.first.map { Date(timeIntervalSince1970: $0.start) }
        let last = model.sessions.last.map { Date(timeIntervalSince1970: $0.end) }
        let span = [first, last].compactMap { $0?.formatted(date: .omitted, time: .shortened) }.joined(separator: " → ")
        return OverviewCard(title: "Sessions", caption: "split where nobody shot for \(model.sessionGapMinutes) min · right-click a session to name it", trailing: span) {
            SessionTimeline { s in
                model.sessionAnchor = s.start
                route = .files
            }
            .frame(height: 46)
        }
    }

    // MARK: - Needs you

    var needsYou: some View {
        OverviewCard(title: "Needs you") {
            let items = attention
            if items.isEmpty {
                Label("Nothing needs you right now", systemImage: "checkmark.circle.fill").foregroundStyle(Color.good)
                    .padding(.vertical, 6)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Circle().fill(item.urgent ? Color.red : Color.notice).frame(width: 8, height: 8)
                    Text(item.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(item.button, action: item.action).controlSize(.small)
                }
                .padding(.vertical, 3)
            }
        }
    }

    struct Attention {
        var text: AttributedString
        var button: String
        var urgent = false
        var action: () -> Void
    }

    var attention: [Attention] {
        var list: [Attention] = []
        func bold(_ b: String, _ rest: String) -> AttributedString {
            var a = AttributedString(b)
            a.font = .body.weight(.semibold)
            return a + AttributedString(rest)
        }
        if unnamed > 0 {
            list.append(Attention(text: bold("\(unnamed) people", " have no name yet"), button: "Name People") { route = .faces(.toName) })
        }
        if cards > 0 {
            list.append(Attention(text: bold("\(cards) card\(cards == 1 ? "" : "s")", " connected — copy what was shot since the last hand-over"), button: "Copy from Cards") { route = .tool(.cards) })
        }
        for s in offline {
            list.append(Attention(text: bold(s.name, " is offline — renamed or moved?"), button: "Locate…", urgent: true) { model.locateSource(s.id) })
        }
        for r in unreachableRules {
            let name = r.displayName { id in model.knownPeople.first { $0.id == id }?.displayName }
            list.append(Attention(text: bold("Rule \(name)", " waits: its folder is not reachable on this Mac"), button: "Open Rules", urgent: true) { route = .faces(.rules) })
        }
        if failed > 0 {
            list.append(Attention(text: bold("\(failed) file\(failed == 1 ? "" : "s")", " could not be read"), button: "Show Files") { route = .files })
        }
        if model.stats.unassignedFaces > 0 && unnamed == 0 {
            list.append(Attention(text: bold("\(model.stats.unassignedFaces) faces", " belong to nobody yet"), button: "Review") { route = .faces(.unassigned) })
        }
        if let team = model.currentTeam, let status = model.teamStatus[team.id!], !status.reachable {
            list.append(Attention(text: bold("Team \(team.name)", " folder is not reachable — syncing resumes when it is back"), button: "Team", urgent: true) { route = .overview })
        }
        return list
    }

    // MARK: - Activity

    var activity: some View {
        OverviewCard(title: "Activity", caption: "this Mac") {
            if model.activity.isEmpty {
                Text("Names, merges, deliveries and folders show up here as they happen.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            }
            ForEach(Array(model.activity.prefix(8).enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider() }
                ActivityRow(item: item).padding(.vertical, 3)
            }
        }
    }
}

/// A rounded panel with a small-caps title; the whole card is a link when `action` is set.
struct OverviewCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let body = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                if let caption { Text("· \(caption)").font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .padding(.bottom, 4)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        if let action {
            Button(action: action) { body.contentShape(RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
        } else {
            body
        }
    }
}

struct BigNumber: View {
    let n: Int
    init(_ n: Int) { self.n = n }
    var body: some View {
        Text(n.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
    }
}

/// A few of the people's faces, overlapping.
struct FaceStack: View {
    let faceIds: [Int64]
    var body: some View {
        HStack(spacing: -8) {
            ForEach(faceIds, id: \.self) { id in
                FaceImage(faceId: id, side: 22).clipShape(Circle())
                    .overlay(Circle().stroke(Color.panel, lineWidth: 2))
            }
        }
        .frame(height: 24)
    }
}

/// One step of the night: number, title, two lines of status; clicking goes to the screen that does it.
struct WorkflowStep<Content: View>: View {
    let number: Int
    let title: String
    let icon: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: icon).foregroundStyle(.secondary)
                    Text("\(number) · \(title)").fontWeight(.semibold)
                }
                content
            }
            .font(.callout)
            .lineLimit(1)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.45)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// The event's sessions side by side, each as wide as its share of the files; a thin one still gets room for
/// its name. Click to open the session's files; right-click to name it.
struct SessionTimeline: View {
    @EnvironmentObject var model: FaceGroupingModel
    let open: (EventSession) -> Void
    @State private var renaming: EventSession?
    @State private var newName = ""

    var body: some View {
        GeometryReader { geo in
            let widths = Self.widths(model.sessions.map { Double($0.photos + $0.videos) }, total: geo.size.width - 3 * Double(max(0, model.sessions.count - 1)))
            HStack(spacing: 3) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { i, s in
                    let selected = model.currentSession?.index == s.index
                    Button { open(s) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.sessionTitle(s)).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(detail(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .frame(width: widths[i], height: geo.size.height, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accent.opacity(selected ? 0.55 : 0.18 + 0.3 * strength(s))))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(model.sessionTime(s)) · \(detail(s)) — click to see these files")
                    .contextMenu {
                        Button("Rename Session…") { newName = s.name ?? ""; renaming = s }
                        if s.name != nil { Button("Remove Name") { model.renameSession(s, to: "") } }
                    }
                }
            }
        }
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName, prompt: Text("e.g. Opening, Final, Awards"))
            Button("Rename") { if let s = renaming { model.renameSession(s, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            if let s = renaming { Text(model.sessionTime(s)) }
        }
    }

    func detail(_ s: EventSession) -> String {
        let n = s.photos + s.videos
        return s.name == nil ? n.formatted() : "\(model.sessionTime(s)) · \(n.formatted())"
    }

    /// 0…1: how busy this session was next to the busiest.
    func strength(_ s: EventSession) -> Double {
        let most = model.sessions.map { $0.photos + $0.videos }.max() ?? 1
        return Double(s.photos + s.videos) / Double(max(1, most))
    }

    /// Widths proportional to `shares`, none under `min`; the rest shrink to make room.
    static func widths(_ shares: [Double], total: Double, min: Double = 64) -> [Double] {
        guard !shares.isEmpty, total > 0 else { return [] }
        let sum = shares.reduce(0, +)
        var w = shares.map { sum > 0 ? total * $0 / sum : total / Double(shares.count) }
        var fixed = Set<Int>()
        for _ in 0..<shares.count {
            let small = w.indices.filter { !fixed.contains($0) && w[$0] < min }
            if small.isEmpty { break }
            small.forEach { fixed.insert($0) }
            let free = w.indices.filter { !fixed.contains($0) }
            let room = total - Double(fixed.count) * min
            let freeSum = free.reduce(0.0) { $0 + shares[$1] }
            for i in free { w[i] = freeSum > 0 ? room * shares[i] / freeSum : room / Double(free.count) }
            for i in fixed { w[i] = min }
        }
        return w.map { Swift.max(0, $0) }
    }
}
