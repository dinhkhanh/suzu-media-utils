import AppKit
import FaceLibrary
import SwiftUI

/// Copies what is new off the photographers' memory cards. Cards are handed over again and again during an event
/// without being erased; the library remembers each card (by its volume UUID) and every file copied from it, so a
/// card's next hand-over copies only what was shot since, however the earlier copies were moved or edited.
///
/// Each mounted card is a panel: what is new on it as a sentence, where it goes, one button. The destination and
/// the options sit in a column on the right.
struct CardCopyTool: View {
    @EnvironmentObject var faces: FaceGroupingModel
    @StateObject private var model = CardCopyModel()
    @AppStorage("cardCopyDestination") private var destinationPath = ""
    @AppStorage("cardCopyVerify") private var verify = true
    @AppStorage("cardCopyPerHandover") private var perHandover = true
    @AppStorage("cardCopyKeepLayout") private var keepLayout = false
    @AppStorage("cardCopyAddToProject") private var addToProject = true
    @AppStorage("cardCopySplitVideos") private var splitVideos = false
    @AppStorage("cardCopyVideoDestination") private var videoDestinationPath = ""
    /// Copies go to the team NAS: to the staging folder on this Mac first, then up by themselves (TeamNASModel).
    @AppStorage("cardCopyToNAS") private var toNAS = false
    /// A sub-folder under the folder on the NAS for this event, when that folder holds several events; empty (the
    /// usual case: the folder on the NAS is the event's) puts the cards straight into it.
    @AppStorage("cardCopyNASEvent") private var nasEventTyped = ""
    @Environment(\.openSettings) private var openSettings

    var nasEvent: String { nasEventTyped.trimmingCharacters(in: .whitespaces) }
    var destination: URL? {
        if toNAS { return faces.nas.stagingFolder(event: nasEvent) }
        return destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath, isDirectory: true)
    }
    var videoDestination: URL? { !toNAS && splitVideos && !videoDestinationPath.isEmpty ? URL(fileURLWithPath: videoDestinationPath, isDirectory: true) : nil }
    /// Where this card's photos go: its own place when it has one (several cards copy side by side to different
    /// disks at full speed), else the folder above. On the way to the NAS, always the staging folder.
    func destination(for card: CardCopyModel.Card) -> URL? { toNAS ? destination : (model.ownDestination(card.id) ?? destination) }
    /// Both places chosen for this card (videos' too, when they have their own); for the NAS, a NAS attached.
    func ready(_ card: CardCopyModel.Card) -> Bool {
        if toNAS { return faces.nas.isConnected }
        return destination(for: card) != nil && (!splitVideos || videoDestination != nil)
    }

    var withNew: [CardCopyModel.Card] { model.cards.filter { c in !c.copying && !c.planning && !c.gone && ready(c) && (c.plan.map { !$0.new.isEmpty } ?? false) } }
    var copying: Int { model.cards.count(where: \.copying) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.cards.isEmpty {
                        noCards
                    }
                    ForEach(model.cards) { card in
                        let free = destination(for: card).flatMap { CardCopier.freeSpace(at: $0) }
                        CardRow(card: card, model: model, canCopy: ready(card), free: free,
                                videoFree: videoDestination.flatMap { CardCopier.freeSpace(at: $0) } ?? free,
                                destination: destination(for: card), videoDestination: videoDestination,
                                nasEvent: toNAS ? (faces.nas.isConnected ? nasEvent : nil) : nil) { copy(card) }
                    }
                    let others = model.known.filter { k in !model.cards.contains { $0.identity.uuid == k.card.uuid } }
                    if !others.isEmpty {
                        knownCards(others)
                    }
                }
                .padding(20)
            }
            Divider()
            options
        }
        .navigationTitle("Copy from Cards")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { model.refresh(store: faces.store, sync: faces.service?.teamSync, fresh: true) } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.looking)
                    .help("Look for cards again (they are also noticed as they mount)")
            }
            ToolbarItem {
                Button("Copy New Files from All") { for c in withNew { copy(c) } }
                    .disabled(withNew.isEmpty)
                    .help("Start every card that has new files, side by side")
            }
        }
        .task { model.refresh(store: faces.store, sync: faces.service?.teamSync) }
        .onChange(of: faces.store == nil) { model.refresh(store: faces.store, sync: faces.service?.teamSync) }
    }

    var subtitle: String {
        let n = model.cards.count { !$0.gone }
        if n == 0 { return "Only what was shot since the last hand-over" }
        var parts = ["\(n) card\(n == 1 ? "" : "s") connected"]
        if !withNew.isEmpty { parts.append("\(withNew.count) with new files") }
        if copying > 0 { parts.append("\(copying) copying") }
        return parts.joined(separator: " · ")
    }

    var noCards: some View {
        HStack(spacing: 14) {
            Image(systemName: "sdcard").font(.system(size: 28)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if model.looking { ProgressView().controlSize(.small) }
                    Text(model.looking ? "Looking for cards…" : "No card connected").font(.headline)
                }
                Text("Insert a card: cards with a DCIM folder show up here as they mount, with what was shot since their last hand-over.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
    }

    func knownCards(_ others: [CardCopier.KnownCard]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("Cards seen before")
                Text("· \(others.count) · right-click to forget one and copy it all again").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 6)
            ForEach(Array(others.enumerated()), id: \.element.id) { i, k in
                if i > 0 { Divider() }
                KnownCardRow(known: k, model: model).padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
    }

    /// The column on the right: where copies go, and how.
    var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Destination")
                    Picker("", selection: $toNAS) {
                        Text("A folder").tag(false)
                        Text("Team NAS").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("A folder: this Mac, a drive or a share. Team NAS: copied to this Mac first, then sent to the team's NAS by itself, from anywhere.")
                    if toNAS {
                        nasBox
                    } else {
                        DestinationBox(title: splitVideos ? "Photos" : "Photos & videos", url: Binding(get: { destination }, set: { destinationPath = $0?.path ?? "" }))
                        LabeledSwitch("Videos go to their own folder", isOn: $splitVideos,
                                      help: "Photos to one place, videos to another (an editor's drive, say); a clip's XML goes with the clip")
                        if splitVideos {
                            DestinationBox(title: "Videos", url: Binding(get: { videoDestinationPath.isEmpty ? nil : URL(fileURLWithPath: videoDestinationPath, isDirectory: true) },
                                                                     set: { videoDestinationPath = $0?.path ?? "" }))
                        }
                        Text("Each card gets its own folder here, named after the card. A card can go somewhere else instead — its panel has a Change… button and remembers it for next time, so cards copying to different disks run side by side at full speed.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Options")
                    LabeledSwitch("Verify each copy", isOn: $verify, help: "Reads every copy back and compares its SHA-256 with the original")
                    LabeledSwitch("A folder per hand-over", isOn: $perHandover, help: "“2026-10-24 14.05” inside the card's folder, so each hand-over is its own session")
                    LabeledSwitch("Keep the card's folders", isOn: $keepLayout, help: "DCIM/100CANON/… as on the card, instead of files side by side")
                    if let p = faces.currentProject {
                        LabeledSwitch("Add the card's folder to “\(faces.projectName)”", isOn: $addToProject, help: "Faces are found and names given as the files land")
                            .id(p)
                    }
                }
                Text("Cards are known by the serial the camera wrote when it formatted them, so the next hand-over copies only what was shot since — however the earlier copies were moved or edited. Files already in the library are matched by contents and never copied twice.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
            }
            .padding(18)
        }
        .frame(width: 320)
        .background(Color.primary.opacity(0.025))
    }

    /// The Team NAS as a destination: the NAS, the event's folder on it, and where the staging copy sits.
    @ViewBuilder var nasBox: some View {
        if let a = faces.nas.attached {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.file.host).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text("\(a.file.basePath)/\(nasEvent.isEmpty ? "" : nasEvent + "/")<card>").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
            TextField("Sub-folder on the NAS (optional)", text: $nasEventTyped, prompt: Text("none: cards go straight into the folder above"))
                .textFieldStyle(.roundedBorder)
                .help("Only when the folder on the NAS holds several events: the event's sub-folder the cards go into")
            Text("The card is copied to \(faces.nas.stagingFolder.lastPathComponent)\(nasEvent.isEmpty ? "" : "/" + nasEvent) on this Mac first (minutes), then sent to the NAS by itself: resumed if the connection drops, checked once there, and the team sees each hand-over only when it is complete. The staging folder mirrors the folder on the NAS: anything else put in it goes up the same way. Progress is in the status pill; the staging folder and the uploads are under Settings → Team NAS.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.xmark").foregroundStyle(Color.notice)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No NAS attached").fontWeight(.semibold).foregroundStyle(Color.notice)
                    Text(faces.teams.isEmpty ? "Join a team first; the NAS comes with it" : "Settings → Team NAS → Attach a NAS…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !faces.teams.isEmpty {
                    Button("Settings…") { openSettings() }.controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        }
    }

    func copy(_ card: CardCopyModel.Card) {
        guard let destination = destination(for: card), let store = faces.store else { return }
        var o = CardCopier.Options(destination: destination)
        o.videoDestination = videoDestination
        o.verify = verify
        o.perHandover = perHandover
        o.keepLayout = keepLayout
        // A hand-over interrupted (card pulled, destination gone, Cancel) goes on in its folder.
        if let last = card.outcome, last.interruption != nil, last.folder.path.hasPrefix(destination.path + "/") {
            o.folder = last.folder
            if let v = videoDestination, let lv = last.videoFolder, lv.path.hasPrefix(v.path + "/") { o.videoFolder = lv }
        }
        let project = addToProject ? faces.currentProject : nil
        if let project, let plan = card.plan {
            // The card's folder joins the project before the first file lands; each file is then taken up the
            // moment it lands and its faces read from the card (local) while it is still in the slot, not back
            // from the share minutes later when the scan gets to it and the card is long gone.
            let folders = [destination.appendingPathComponent(CardCopier.cardFolderName(plan.card), isDirectory: true)]
                + (videoDestination.map { [$0.appendingPathComponent(CardCopier.cardFolderName(plan.card), isDirectory: true)] } ?? [])
            for f in folders {
                try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
                faces.addCopiedFolder(f, project: project)
            }
            if let service = faces.service {
                o.onCopied = { landed in service.fileLanded(landed) }
            }
        }
        let toNAS = toNAS, event = nasEvent, perHandover = perHandover
        model.copy(card.id, options: o, store: store) { outcome in
            if let project, !outcome.copied.isEmpty || !outcome.skipped.isEmpty {
                faces.addCopiedFolder(outcome.cardFolder, project: project)
                if let v = outcome.videoCardFolder { faces.addCopiedFolder(v, project: project) }
            }
            // What landed goes up, even after an interruption: the rest follows on the next copy, into the same
            // hand-over folder, and the upload picks up what is new there.
            if toNAS, let plan = card.plan, !outcome.copied.isEmpty || !outcome.skipped.isEmpty {
                faces.nas.enqueueCard(event: event, card: plan.card, handover: perHandover ? outcome.folder.lastPathComponent : nil, outcome: outcome)
            }
        }
    }
}

/// A folder chosen as a destination: its name, the disk's free space, and Change.
struct DestinationBox: View {
    let title: String
    @Binding var url: URL?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: url == nil ? "folder.badge.questionmark" : "externaldrive").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url?.lastPathComponent ?? "Choose a folder").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(url == nil ? Color.notice : .primary)
                Text(url.map { u in "\(title) · \(u.deletingLastPathComponent().path)" + (CardCopier.freeSpace(at: u).map { " · \($0.formatted(.byteCount(style: .file))) free" } ?? "") } ?? "\(title) · nothing chosen yet")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(url == nil ? "Choose…" : "Change") { Panels.chooseFolder(key: "cardCopy.destination") { url = $0 } }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        .help(url?.path ?? "")
    }
}

/// One mounted card as a panel: its name (editable), camera and room; what is new as a sentence; where it goes;
/// the copy's progress or result; and one button.
struct CardRow: View {
    let card: CardCopyModel.Card
    @ObservedObject var model: CardCopyModel
    let canCopy: Bool
    /// Room at the destinations, when known (videos' is the photos' when they share one).
    let free: Int64?
    let videoFree: Int64?
    let destination: URL?
    let videoDestination: URL?
    /// On the way to the team NAS: the event's folder there (the copy lands in `destination`, the staging folder,
    /// first).
    let nasEvent: String?
    let copy: () -> Void
    @State private var label: String
    @EnvironmentObject var faces: FaceGroupingModel

    init(card: CardCopyModel.Card, model: CardCopyModel, canCopy: Bool, free: Int64?, videoFree: Int64?,
         destination: URL?, videoDestination: URL?, nasEvent: String? = nil, copy: @escaping () -> Void) {
        self.card = card
        self.model = model
        self.canCopy = canCopy
        self.free = free
        self.videoFree = videoFree
        self.destination = destination
        self.videoDestination = videoDestination
        self.nasEvent = nasEvent
        self.copy = copy
        _label = State(initialValue: card.plan?.card.label ?? "")
    }

    func tooBig(_ p: CardCopier.Plan) -> Bool {
        if videoFree != nil, videoFree != free {
            return (free.map { p.newBytes(.photo) > $0 } ?? false) || (videoFree.map { p.newBytes(.video) > $0 } ?? false)
        }
        return free.map { p.newBytes > $0 } ?? false
    }

    var hasNew: Bool { card.plan.map { !$0.new.isEmpty } ?? false }

    /// "SONY ILCE-7M4 · 5203… · 128 GB · 64 GB free".
    var details: String {
        var parts: [String] = []
        if let camera = card.plan?.card.camera ?? card.identity.cameraMake { parts.append(camera) }
        if let s = card.identity.cameraSerial { parts.append(s) }
        if let cap = card.identity.capacity { parts.append(cap.formatted(.byteCount(style: .file))) }
        if let free = card.identity.available { parts.append("\(free.formatted(.byteCount(style: .file))) free") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sdcard.fill").font(.system(size: 34)).foregroundStyle(card.gone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .frame(width: 44)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                // Line 1: the card and its name, the state on the right. Line 2: the camera and the card's room.
                // Nothing here wraps: a long name truncates instead of breaking the row into a word per line.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(card.identity.volumeName).font(.title3.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        TextField("", text: $label, prompt: Text("Name this card, e.g. Nam R5 card 1"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 220)
                            .onSubmit { rename(card.plan?.card.label) }
                            .help("A name for this card. The card itself is not renamed; it is known by its volume UUID.")
                        Spacer(minLength: 8)
                        statusPill.fixedSize()
                    }
                    if !details.isEmpty {
                        Text(details).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                status
                if let o = card.outcome { outcome(o) }
                if let e = card.error { Text(e).foregroundStyle(.red).font(.callout) }
            }
            if !card.gone && !card.planning {
                VStack(spacing: 6) {
                    // Labels fill the column, so the buttons are one width.
                    if card.copying {
                        Button { model.cancel(card.id) } label: { Text("Stop").frame(maxWidth: .infinity) }
                    } else if let p = card.plan {
                        // Other cards may be copying meanwhile: to other disks at full speed, to the same one side by side.
                        Button { copy() } label: { Text("Copy New Files").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canCopy || p.new.isEmpty || tooBig(p))
                            .help(canCopy ? "" : "Choose a destination folder first")
                        Button { model.eject(card.id) } label: { Text("Eject").frame(maxWidth: .infinity) }
                    }
                }
                .frame(width: 140)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hasNew && !card.copying && !card.gone ? Color.notice.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1))
        .onChange(of: card.plan?.card.label) { label = card.plan?.card.label ?? "" }
    }

    @ViewBuilder var statusPill: some View {
        if card.gone {
            pill("Removed", color: .orange)
        } else if card.planning {
            pill(card.plan == nil ? "Looking…" : "Looking again…", color: .secondary)
        } else if card.copying {
            pill("Copying", color: .accent, dot: true)
        } else if let p = card.plan {
            if p.new.isEmpty {
                pill("Up to date", color: .good, icon: "checkmark")
            } else if let at = p.card.lastCopiedAt {
                pill("New since \(at.formatted(date: .omitted, time: .shortened))", color: .notice)
            } else {
                pill("Never copied", color: .notice)
            }
        }
    }

    func pill(_ text: String, color: Color, icon: String? = nil, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 7, height: 7) }
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .foregroundStyle(color)
    }

    @ViewBuilder
    var status: some View {
        if card.gone {
            Text(card.copying ? "The card was removed." : card.outcome?.interruption == nil ? "The card was removed." : "The card was removed. Put it back to go on.")
                .foregroundStyle(.orange)
        } else if card.planning, card.plan == nil {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking at the card…").foregroundStyle(.secondary) }
        } else if card.copying {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(card.progress.bytesDone), total: Double(max(1, card.progress.bytesTotal)))
                HStack(spacing: 14) {
                    Text("\(card.progress.done.formatted()) of \(card.progress.total.formatted()) files").fontWeight(.semibold)
                    Text("\(card.progress.bytesDone.formatted(.byteCount(style: .file))) of \(card.progress.bytesTotal.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary)
                    Text(card.progress.current).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                .monospacedDigit()
                Text("Pulling the card stops the copy at once; nothing half-written is left, and it goes on in the same folder when the card is back.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } else if let p = card.plan {
            VStack(alignment: .leading, spacing: 4) {
                summaryText(p)
                if let at = p.card.lastCopiedAt {
                    Text("Last copied \(at.formatted(date: .abbreviated, time: .shortened))\(p.card.lastCopiedTo.map { " to \(($0 as NSString).lastPathComponent)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                destinationLine(p)
                if tooBig(p), let free {
                    Label("Not enough room at the destination: \(free.formatted(.byteCount(style: .file))) free.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// "312 new photos · 14 new videos · 9.8 GB · 1,208 copied before".
    func summaryText(_ p: CardCopier.Plan) -> some View {
        var head = Text("")
        if p.files.isEmpty {
            head = Text("No photos or videos on the card")
        } else if p.new.isEmpty {
            head = Text("Nothing new")
        } else {
            var what: [String] = []
            if p.newPhotos > 0 { what.append("\(p.newPhotos.formatted()) new photo\(p.newPhotos == 1 ? "" : "s")") }
            if p.newVideos > 0 { what.append("\(p.newVideos.formatted()) new video\(p.newVideos == 1 ? "" : "s")") }
            if what.isEmpty { what.append("\(p.new.count) new") }
            head = Text(what.joined(separator: " · ")).fontWeight(.semibold) + Text(" · \(p.newBytes.formatted(.byteCount(style: .file)))")
        }
        var rest: [String] = []
        if !p.copiedBefore.isEmpty {
            rest.append(p.copiedElsewhere == 0 ? "\(p.copiedBefore.count.formatted()) copied before"
                        : p.copiedElsewhere == p.copiedBefore.count ? "\(p.copiedBefore.count.formatted()) copied on a teammate's Mac"
                        : "\(p.copiedBefore.count.formatted()) copied before (\(p.copiedElsewhere) on a teammate's Mac)")
        }
        if !p.inLibrary.isEmpty { rest.append("\(p.inLibrary.count.formatted()) already in the library") }
        return (head + Text(rest.isEmpty ? "" : " · " + rest.joined(separator: " · ")).foregroundStyle(.secondary))
            .font(.body)
    }

    /// Where the photos (and videos) will land, and the menu to send this card somewhere else.
    func destinationLine(_ p: CardCopier.Plan) -> some View {
        let folder = CardCopier.cardFolderName(p.card)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
            if let nasEvent, let destination {
                Text("Team NAS → \(nasEvent.isEmpty ? "" : nasEvent + "/")\(folder) · via \(destination.lastPathComponent) on this Mac")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("Copied to \(destination.appendingPathComponent(folder).path) first, then sent to the NAS by itself")
            } else if let destination {
                Text("Photos → \(destination.lastPathComponent)/\(folder)" + (videoDestination.map { " · Videos → \($0.lastPathComponent)/\(folder)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(destination.appendingPathComponent(folder).path)
            } else {
                Text("Choose a destination folder on the right").font(.caption).foregroundStyle(Color.notice)
            }
            if nasEvent == nil { destinationMenu }
        }
    }

    /// Where this card goes: the folder above (the default) or one of its own, remembered for the card's next
    /// hand-over too, so the SSD card keeps going to the SSD.
    var destinationMenu: some View {
        let own = model.ownDestination(card.id)
        return Menu {
            Button("The Destination Folder") { model.setOwnDestination(card.id, nil) }.disabled(own == nil)
            Button("Another Folder for This Card…") { Panels.chooseFolder(key: "cardCopy.destination") { model.setOwnDestination(card.id, $0) } }
        } label: {
            Text(own == nil ? "Change…" : "Own folder: \(own!.lastPathComponent)").font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(own.map { "This card copies into \($0.path)" } ?? "This card copies into the destination folder. Pick another folder to copy this card to a different disk, side by side with the other cards.")
    }

    /// Saves a name typed in. An empty or unchanged field is left alone: a field ending its editing when the window
    /// closes must never wipe a name.
    func rename(_ current: String?) {
        let typed = label.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != (current ?? "") else { return }
        model.setLabel(card.id, typed, store: faces.store)
    }

    func outcomeText(_ o: CardCopier.Outcome) -> String {
        let took = Int(o.finished.timeIntervalSince(o.started).rounded())
        let time = took >= 60 ? "\(took / 60) min \(took % 60) s" : "\(took) s"
        var s = switch o.interruption {
        case .cancelled: "Stopped: copied "
        case .cardRemoved: "The card was removed in the middle of the copy: "
        case .destinationLost: "The destination went away in the middle of the copy: "
        case nil: "Copied "
        }
        s += "\(o.copied.count) files (\(o.bytes.formatted(.byteCount(style: .file))))"
        if !o.skipped.isEmpty { s += ", \(o.skipped.count) already there" }
        s += " in \(time)"
        if o.interruption != nil, o.interruption != .cancelled { s += ". Those are safe; the rest is still new and goes on in the same folder." }
        return s
    }

    @ViewBuilder
    func outcome(_ o: CardCopier.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(outcomeText(o), systemImage: o.interruption == nil && o.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(o.failed.isEmpty && o.interruption == nil ? Color.good : Color.orange)
                Spacer()
                Button(o.videoFolder == nil ? "Show in Finder" : "Show Photos") { NSWorkspace.shared.activateFileViewerSelecting([o.folder]) }.controlSize(.small)
                if let v = o.videoFolder { Button("Show Videos") { NSWorkspace.shared.activateFileViewerSelecting([v]) }.controlSize(.small) }
            }
            if !o.failed.isEmpty {
                DisclosureGroup("\(o.failed.count) files could not be copied (still on the card; try again)") {
                    ForEach(o.failed.prefix(100), id: \.file) { f in
                        Text("\(f.file): \(f.reason)").font(.caption.monospaced())
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

struct KnownCardRow: View {
    let known: CardCopier.KnownCard
    @ObservedObject var model: CardCopyModel
    @EnvironmentObject var faces: FaceGroupingModel
    @State private var label: String

    init(known: CardCopier.KnownCard, model: CardCopyModel) {
        self.known = known
        self.model = model
        _label = State(initialValue: known.card.label ?? "")
    }

    var body: some View {
        // Columns that line up from row to row: card, name, camera, then the counts on the right.
        HStack(spacing: 10) {
            Image(systemName: "sdcard").foregroundStyle(.secondary).frame(width: 18)
            Text(known.card.volumeName ?? "Card").fontWeight(.semibold)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 130, alignment: .leading)
            TextField("", text: $label, prompt: Text("Name this card"))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                .onSubmit {
                    let typed = label.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty, typed != (known.card.label ?? "") { model.setLabel(known.card.uuid, typed, store: faces.store) }
                }
            Text(known.card.camera ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(known.files) files · \(known.bytes.formatted(.byteCount(style: .file)))" +
                 (known.card.lastCopiedAt.map { " · last \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .onChange(of: known.card.label) { label = known.card.label ?? "" }
        .contextMenu {
            Button("Forget This Card") { model.forget(known.id, store: faces.store) }
        }
        .help("Right-click to forget the card: its next hand-over copies everything again")
    }
}

/// The mounted cards and what the library knows of them. Looks again whenever a volume mounts or unmounts.
@MainActor
final class CardCopyModel: ObservableObject {
    /// One look at a card (its plan being made). The card holds the look under way; a result from any other look
    /// (an older one, or one at a card since pulled and put back) is dropped.
    final class Look: @unchecked Sendable { var cancelled = false }

    struct Card: Identifiable {
        var identity: CardCopier.Identity
        var plan: CardCopier.Plan?
        /// The look under way (a card is listed and its look started in one go, so it shows the spinner from the
        /// moment it appears) until its plan or error is in. Nil otherwise.
        var look: Look?
        var planning: Bool { look != nil }
        /// Look once more when the look under way is done: the ledger changed meanwhile (the earlier plan's
        /// fingerprints are reused, so that is a listing and a lookup).
        var lookAgain = false
        var copying = false
        var progress = CardCopier.Progress()
        var outcome: CardCopier.Outcome?
        var error: String?
        /// Unmounted while it was being copied, or after an interrupted copy: kept on screen so the result shows.
        var gone = false
        var id: String { identity.uuid }
    }

    @Published var cards: [Card] = []
    @Published var known: [CardCopier.KnownCard] = []
    @Published var looking = false
    /// Cards with a destination of their own, by volume UUID (this Mac's paths: not part of the team's ledger).
    @Published private(set) var ownDestinations: [String: String] = UserDefaults.standard.dictionary(forKey: "cardCopyOwnDestinations") as? [String: String] ?? [:]
    private var again = false
    private var againFresh = false
    private var observers: [NSObjectProtocol] = []
    private var cancels: [String: Cancel] = [:]
    private var pending: LibraryStore?
    private var pendingSync: TeamSync?

    final class Cancel: @unchecked Sendable { var flag = false }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(store: self?.pending, sync: self?.pendingSync) }
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

    /// Looks for cards and what is new on them. The cards show at once; with a team, the teammates' logs are read
    /// in the background and a card's plan is made again if they brought a copy made on another Mac (reading them
    /// first used to hold the cards up for as long as a sync pass took, which under heavy processing is a while).
    ///
    /// A card already planned keeps its plan when another card mounts or unmounts; `fresh` (Look Again, or another
    /// library) plans every card again, and a card whose look failed is looked at once more either way.
    func refresh(store: LibraryStore?, sync: TeamSync? = nil, fresh: Bool = false) {
        let fresh = fresh || pending !== store
        pending = store
        pendingSync = sync
        guard let store else { return }
        // A card mounted while the last look was under way: look once more when it is done.
        if looking { again = true; againFresh = againFresh || fresh; return }
        looking = true
        Task {
            let (found, seen) = await Task.detached(priority: .userInitiated) { () -> ([CardCopier.Identity], [CardCopier.KnownCard]) in
                (Self.volumes.compactMap { CardCopier.identify($0) }, (try? CardCopier.knownCards(store: store)) ?? [])
            }.value
            // Cards still there keep their state. A card back after being pulled starts over, keeping an interrupted
            // copy's result so the next copy goes on in its folder. A card pulled in the middle of its copy, or
            // after one, stays on screen; its look, if one was under way, is dropped with it.
            var next: [Card] = []
            var toPlan: [String] = []
            for id in found {
                if let c = cards.first(where: { $0.id == id.uuid }), !c.gone {
                    var kept = c
                    kept.identity = id
                    next.append(kept)
                    if !c.copying, fresh || (c.plan == nil && c.look == nil) { toPlan.append(id.uuid) }
                } else {
                    var c = Card(identity: id)
                    if let before = cards.first(where: { $0.id == id.uuid })?.outcome, before.interruption != nil { c.outcome = before }
                    next.append(c)
                    toPlan.append(id.uuid)
                }
            }
            for c in cards where !found.contains(where: { $0.uuid == c.id }) {
                c.look?.cancelled = true
                guard c.copying || c.outcome != nil else { continue }
                var g = c
                g.gone = true
                g.look = nil
                g.lookAgain = false
                next.append(g)
            }
            cards = next
            known = seen
            looking = false
            for id in toPlan { plan(id, store: store) }
            if again { again = false; let f = againFresh; againFresh = false; refresh(store: store, sync: sync, fresh: f) }
            if let sync, !found.isEmpty { catchUp(sync, store: store) }
        }
    }

    /// The team's ledger, without holding the cards up: one sync pass in the background; if it brought copies
    /// teammates made, each card is planned again (from the fingerprints the plan already read, in milliseconds)
    /// so those files aren't copied twice.
    func catchUp(_ sync: TeamSync, store: LibraryStore) {
        let before = CardCopier.teammateCopies(store: store)
        sync.syncSoon { [weak self] in
            guard CardCopier.teammateCopies(store: store) > before else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                known = (try? CardCopier.knownCards(store: store)) ?? known
                for c in cards where !c.copying && !c.gone { plan(c.id, store: store) }
            }
        }
    }

    /// Makes the card's plan: every new file's fingerprint, matched against the ledger and the library. While a
    /// look is under way the card can't be copied, and a request meanwhile only asks for one more look when it is
    /// done (from the fingerprints just read). The result lands only if this look is still the card's.
    func plan(_ id: String, store: LibraryStore) {
        guard let i = cards.firstIndex(where: { $0.id == id }), !cards[i].copying, !cards[i].gone else { return }
        if cards[i].look != nil { cards[i].lookAgain = true; return }
        let look = Look()
        cards[i].look = look
        cards[i].lookAgain = false
        cards[i].error = nil
        let identity = cards[i].identity
        let previous = cards[i].plan
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CardCopier.plan(identity, store: store, previous: previous, isCancelled: { look.cancelled }) }
            }.value
            guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].look === look else { return }
            cards[i].look = nil
            switch result {
            case .success(let p): cards[i].plan = p
            case .failure(let e): cards[i].error = e.localizedDescription
            }
            if cards[i].lookAgain { plan(id, store: store) }
        }
    }

    func copy(_ id: String, options: CardCopier.Options, store: LibraryStore, done: @escaping (CardCopier.Outcome) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }), let todo = cards[i].plan, !cards[i].copying, !cards[i].planning else { return }
        cards[i].copying = true
        cards[i].outcome = nil
        cards[i].error = nil
        cards[i].progress = CardCopier.Progress(total: todo.new.count, bytesTotal: todo.newBytes)
        let cancel = Cancel()
        cancels[id] = cancel
        ToolWork.begin()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                // Progress arrives per 8 MB piece; the screen gets it a few times a second and at every file's end,
                // so several cards copying at once don't keep the main thread redrawing.
                let throttle = ProgressThrottle()
                return CardCopier.copy(todo, options: options, store: store, progress: { p in
                    guard throttle.due(p) else { return }
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
            if outcome.interruption == .cardRemoved || cards[i].gone || !cards[i].identity.isReachable {
                cards[i].gone = true
                cards[i].plan = nil
            } else {
                plan(id, store: store)
            }
        }
    }

    func cancel(_ id: String) { cancels[id]?.flag = true }

    /// Lets a progress report through when a file finished or 0.25 s passed since the last one. Used from one
    /// copying thread at a time.
    final class ProgressThrottle: @unchecked Sendable {
        private var last = Date.distantPast
        private var files = -1
        func due(_ p: CardCopier.Progress) -> Bool {
            let now = Date()
            guard p.done != files || now.timeIntervalSince(last) >= 0.25 else { return false }
            last = now
            files = p.done
            return true
        }
    }

    func ownDestination(_ uuid: String) -> URL? { ownDestinations[uuid].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func setOwnDestination(_ uuid: String, _ url: URL?) {
        ownDestinations[uuid] = url?.path
        UserDefaults.standard.set(ownDestinations, forKey: "cardCopyOwnDestinations")
    }

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
            c.look?.cancelled = true
            cards.removeAll { $0.id == id }
        } catch {
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].error = error.localizedDescription }
        }
    }
}
