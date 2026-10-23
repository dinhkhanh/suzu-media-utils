import AppKit
import FaceLibrary
import SwiftUI

/// Copies what is new off the photographers' memory cards. Cards are handed over again and again during an event
/// without being erased; the library remembers each card (by its volume UUID) and every file copied from it, so a
/// card's next hand-over copies only what was shot since, however the earlier copies were moved or edited.
struct CardCopyTool: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @StateObject private var model = CardCopyModel()
    @AppStorage("cardCopyDestination") private var destinationPath = ""
    @AppStorage("cardCopyVerify") private var verify = true
    @AppStorage("cardCopyPerHandover") private var perHandover = true
    @AppStorage("cardCopyKeepLayout") private var keepLayout = false
    @AppStorage("cardCopyAddToProject") private var addToProject = true

    var destination: URL? { destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath, isDirectory: true) }

    var body: some View {
        Form {
            Section("Destination") {
                FolderField(title: "Copy into", url: Binding(get: { destination }, set: { destinationPath = $0?.path ?? "" }))
                Text("Each card gets its own folder here, named after the card.").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 14) {
                    Toggle("Verify each copy", isOn: $verify).help("Reads every copy back and compares its SHA-256 with the original")
                    Toggle("A folder per hand-over", isOn: $perHandover).help("“2026-10-24 14.05” inside the card's folder, so each hand-over is its own session")
                    Toggle("Keep the card's folders", isOn: $keepLayout).help("DCIM/100CANON/… as on the card, instead of files side by side")
                    if let p = faces.currentProject {
                        Toggle("Add the card's folder to “\(faces.projectName)”", isOn: $addToProject)
                            .help("Faces are found and names given as the files land")
                            .id(p)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Section {
                if model.cards.isEmpty {
                    HStack {
                        if model.looking { ProgressView().controlSize(.small) }
                        Text(model.looking ? "Looking for cards…" : "Insert a card. Cards with a DCIM folder show up here as they mount.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let free = destination.flatMap { CardCopier.freeSpace(at: $0) }
                    ForEach(model.cards) { card in
                        CardRow(card: card, model: model, canCopy: destination != nil, free: free) { copy(card) }
                    }
                }
            } header: {
                HStack {
                    Text("Cards")
                    Spacer()
                    Button("Look Again") { model.refresh(store: faces.store) }.controlSize(.small).disabled(model.looking)
                }
            }
            let others = model.known.filter { k in !model.cards.contains { $0.identity.uuid == k.card.uuid } }
            if !others.isEmpty {
                Section("Cards seen before") {
                    ForEach(others) { k in
                        KnownCardRow(known: k, model: model)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Copy from Cards")
        .navigationSubtitle("Only what was shot since the last hand-over")
        .task { model.refresh(store: faces.store) }
        .onChange(of: faces.store == nil) { model.refresh(store: faces.store) }
    }

    func copy(_ card: CardCopyModel.Card) {
        guard let destination, let store = faces.store else { return }
        var o = CardCopier.Options(destination: destination)
        o.verify = verify
        o.perHandover = perHandover
        o.keepLayout = keepLayout
        let project = addToProject ? faces.currentProject : nil
        model.copy(card.id, options: o, store: store) { outcome in
            if let project, !outcome.copied.isEmpty || !outcome.skipped.isEmpty {
                faces.addCopiedFolder(outcome.cardFolder, project: project)
            }
        }
    }
}

/// One mounted card: its name (editable), camera, what is new, and the copy's progress or result.
struct CardRow: View {
    let card: CardCopyModel.Card
    @ObservedObject var model: CardCopyModel
    let canCopy: Bool
    /// Room at the destination, when it is known.
    let free: Int64?
    let copy: () -> Void
    @State private var label = ""
    @EnvironmentObject var faces: FaceGroupingModel

    func tooBig(_ p: CardCopier.Plan) -> Bool { free.map { p.newBytes > $0 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard").font(.title2).foregroundStyle(.tint)
                Text(card.identity.volumeName).fontWeight(.semibold)
                TextField("", text: $label, prompt: Text("Name this card, e.g. Nam R5 card 1"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .onSubmit { model.setLabel(card.id, label, store: faces.store) }
                    .help("A name for this card. The card itself is not renamed; it is known by its volume UUID.")
                if let camera = card.plan?.card.camera ?? card.identity.cameraMake {
                    Text(camera + (card.identity.cameraSerial.map { " · \($0)" } ?? "")).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let cap = card.identity.capacity, let free = card.identity.available {
                    Text("\(free.formatted(.byteCount(style: .file))) free of \(cap.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            status
            if let o = card.outcome { outcome(o) }
            if let e = card.error { Text(e).foregroundStyle(.red).font(.callout) }
        }
        .padding(.vertical, 4)
        .onAppear { label = card.plan?.card.label ?? "" }
        .onChange(of: card.plan?.card.label) { label = card.plan?.card.label ?? "" }
    }

    @ViewBuilder
    var status: some View {
        if card.planning {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking at the card…").foregroundStyle(.secondary) }
        } else if card.copying {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(card.progress.bytesDone), total: Double(max(1, card.progress.bytesTotal)))
                HStack {
                    Text("\(card.progress.done) of \(card.progress.total) · \(card.progress.bytesDone.formatted(.byteCount(style: .file))) of \(card.progress.bytesTotal.formatted(.byteCount(style: .file))) · \(card.progress.current)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancel(card.id) }.controlSize(.small)
                }
            }
        } else if let p = card.plan {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary(p)).fontWeight(p.new.isEmpty ? .regular : .semibold)
                    if let at = p.card.lastCopiedAt {
                        Text("Last copied \(at.formatted(date: .abbreviated, time: .shortened))\(p.card.lastCopiedTo.map { " to \(($0 as NSString).lastPathComponent)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Never copied from").font(.caption).foregroundStyle(.secondary)
                    }
                    if tooBig(p), let free {
                        Text("Not enough room at the destination: \(free.formatted(.byteCount(style: .file))) free.").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Eject") { model.eject(card.id) }.controlSize(.small)
                Button("Copy New Files") { copy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCopy || p.new.isEmpty || tooBig(p) || model.cards.contains { $0.copying })
                    .help(canCopy ? "" : "Choose a destination folder first")
            }
        }
    }

    func summary(_ p: CardCopier.Plan) -> String {
        var parts: [String] = []
        parts.append(p.new.isEmpty ? "Nothing new" : "\(p.new.count) new · \(p.newBytes.formatted(.byteCount(style: .file)))")
        if !p.copiedBefore.isEmpty { parts.append("\(p.copiedBefore.count) copied before") }
        if !p.inLibrary.isEmpty { parts.append("\(p.inLibrary.count) already in the library") }
        if p.files.isEmpty { parts = ["No photos or videos on the card"] }
        return parts.joined(separator: " · ")
    }

    func outcomeText(_ o: CardCopier.Outcome) -> String {
        let took = Int(o.finished.timeIntervalSince(o.started).rounded())
        let time = took >= 60 ? "\(took / 60) min \(took % 60) s" : "\(took) s"
        var s = o.cancelled ? "Stopped: copied " : "Copied "
        s += "\(o.copied.count) files (\(o.bytes.formatted(.byteCount(style: .file))))"
        if !o.skipped.isEmpty { s += ", \(o.skipped.count) already there" }
        return s + " in \(time)"
    }

    @ViewBuilder
    func outcome(_ o: CardCopier.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(outcomeText(o)).foregroundStyle(o.failed.isEmpty ? Color.primary : Color.orange)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([o.folder]) }.controlSize(.small)
            }
            if !o.failed.isEmpty {
                DisclosureGroup("\(o.failed.count) files could not be copied (still on the card; try again)") {
                    ForEach(o.failed.prefix(100), id: \.file) { f in
                        Text("\(f.file): \(f.reason)").font(.caption.monospaced())
                    }
                }
            }
        }
    }
}

struct KnownCardRow: View {
    let known: CardCopier.KnownCard
    @ObservedObject var model: CardCopyModel
    @EnvironmentObject var faces: FaceGroupingModel
    @State private var label = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sdcard").foregroundStyle(.secondary)
            Text(known.card.volumeName ?? "Card").fontWeight(.semibold)
            TextField("", text: $label, prompt: Text("Name this card"))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                .onSubmit { model.setLabel(known.card.uuid, label, store: faces.store) }
            if let c = known.card.camera { Text(c).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text("\(known.files) files · \(known.bytes.formatted(.byteCount(style: .file)))" +
                 (known.card.lastCopiedAt.map { " · last \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { label = known.card.label ?? "" }
        .contextMenu {
            Button("Forget This Card") { model.forget(known.id, store: faces.store) }
        }
        .help("Right-click to forget the card: its next hand-over copies everything again")
    }
}

/// The mounted cards and what the library knows of them. Looks again whenever a volume mounts or unmounts.
@MainActor
final class CardCopyModel: ObservableObject {
    struct Card: Identifiable {
        var identity: CardCopier.Identity
        var plan: CardCopier.Plan?
        var planning = true
        var copying = false
        var progress = CardCopier.Progress()
        var outcome: CardCopier.Outcome?
        var error: String?
        var id: String { identity.uuid }
    }

    @Published var cards: [Card] = []
    @Published var known: [CardCopier.KnownCard] = []
    @Published var looking = false
    private var again = false
    private var observers: [NSObjectProtocol] = []
    private var cancels: [String: Cancel] = [:]
    private var pending: LibraryStore?

    final class Cancel: @unchecked Sendable { var flag = false }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(store: self?.pending) }
            })
        }
    }

    deinit {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// SUZU_CARD_VOLUMES=/a:/b (testing): folders that stand for cards.
    nonisolated static var volumes: [URL] {
        if let v = ProcessInfo.processInfo.environment["SUZU_CARD_VOLUMES"] {
            return v.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        return CardCopier.mountedCards()
    }

    func refresh(store: LibraryStore?) {
        pending = store
        guard let store else { return }
        // A card mounted while the last look was under way: look once more when it is done.
        if looking { again = true; return }
        looking = true
        let busy = Set(cards.filter(\.copying).map(\.id))
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [CardCopier.Identity] in
                Self.volumes.compactMap { CardCopier.identify($0) }
            }.value
            // Cards being copied keep their state; the others start over.
            var next: [Card] = []
            for id in found {
                if busy.contains(id.uuid), let c = cards.first(where: { $0.id == id.uuid }) { next.append(c) } else { next.append(Card(identity: id)) }
            }
            cards = next
            known = (try? CardCopier.knownCards(store: store)) ?? []
            looking = false
            for id in found where !busy.contains(id.uuid) { plan(id.uuid, store: store) }
            if again { again = false; refresh(store: store) }
        }
    }

    func plan(_ id: String, store: LibraryStore) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].planning = true
        cards[i].error = nil
        let identity = cards[i].identity
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try CardCopier.plan(identity, store: store) } }.value
            guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
            cards[i].planning = false
            switch result {
            case .success(let p): cards[i].plan = p
            case .failure(let e): cards[i].error = e.localizedDescription
            }
        }
    }

    func copy(_ id: String, options: CardCopier.Options, store: LibraryStore, done: @escaping (CardCopier.Outcome) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }), let todo = cards[i].plan, !cards[i].copying else { return }
        cards[i].copying = true
        cards[i].outcome = nil
        cards[i].error = nil
        cards[i].progress = CardCopier.Progress(total: todo.new.count, bytesTotal: todo.newBytes)
        let cancel = Cancel()
        cancels[id] = cancel
        ToolWork.begin()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                CardCopier.copy(todo, options: options, store: store, progress: { p in
                    Task { @MainActor in
                        if let i = self.cards.firstIndex(where: { $0.id == id }) { self.cards[i].progress = p }
                    }
                }, isCancelled: { cancel.flag })
            }.value
            ToolWork.end()
            cancels[id] = nil
            known = (try? CardCopier.knownCards(store: store)) ?? []
            guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
            cards[i].copying = false
            cards[i].outcome = outcome
            done(outcome)
            plan(id, store: store)
        }
    }

    func cancel(_ id: String) { cancels[id]?.flag = true }

    func setLabel(_ uuid: String, _ label: String, store: LibraryStore?) {
        guard let store, let cardId = (cards.first { $0.id == uuid }?.plan?.card.id) ?? (known.first { $0.card.uuid == uuid }?.id) else { return }
        try? CardCopier.setLabel(label, card: cardId, store: store)
        known = (try? CardCopier.knownCards(store: store)) ?? []
        if let i = cards.firstIndex(where: { $0.id == uuid }) { cards[i].plan?.card.label = label.isEmpty ? nil : label }
    }

    func forget(_ cardId: Int64, store: LibraryStore?) {
        guard let store else { return }
        try? CardCopier.forget(card: cardId, store: store)
        known = (try? CardCopier.knownCards(store: store)) ?? []
    }

    func eject(_ id: String) {
        guard let c = cards.first(where: { $0.id == id }) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: c.identity.volume)
            cards.removeAll { $0.id == id }
        } catch {
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].error = error.localizedDescription }
        }
    }
}
