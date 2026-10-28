import FaceLibrary
import SwiftUI

struct FaceGroupingSettings: View {
    @EnvironmentObject var model: FaceGroupingModel
    @State private var accessKeyId = AWSSettings.credentials?.accessKeyId ?? ""
    @State private var secret = AWSSettings.credentials?.secretAccessKey ?? ""
    @State private var region = AWSSettings.region
    @State private var minConfidence = AWSSettings.minConfidence
    @State private var testResult: String?
    @State private var testing = false

    static let regions = [
        ("ap-southeast-1", "Asia Pacific (Singapore) — closest to Vietnam"),
        ("ap-northeast-1", "Asia Pacific (Tokyo)"),
        ("ap-south-1", "Asia Pacific (Mumbai)"),
        ("us-east-1", "US East (N. Virginia)"),
        ("us-west-2", "US West (Oregon)"),
        ("eu-west-1", "Europe (Ireland)"),
        ("eu-central-1", "Europe (Frankfurt)"),
    ]

    /// Settings → Face Grouping → Other projects' folders: seconds between looks, 0 = only while open.
    static let otherProjectsPaces: [(Double, String)] = [
        (SourceMonitor.slowPoll, "Every 30 seconds, like the open project"),
        (300, "Every 5 minutes"),
        (900, "Every 15 minutes"),
        (3600, "Every hour"),
        (0, "Only while their project is open"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Look for new files", selection: $model.otherProjectsEvery) {
                    ForEach(Self.otherProjectsPaces, id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: {
                Text("Other projects' folders")
            } footer: {
                Text("The open project's folders and the known-people folders are always watched. Less often means less work for the NAS; new photos in another project get their faces later. When this Mac processes faces for the team, a teammate's new photos in a project you don't have open wait for it too. Opening a project looks at its folders at once.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Access Key ID", text: $accessKeyId, prompt: Text("AKIA…"))
                SecureField("Secret Access Key", text: $secret)
                Picker("Region", selection: $region) {
                    ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Minimum confidence") {
                    HStack {
                        Slider(value: $minConfidence, in: 80...99, step: 1)
                        Text("\(Int(minConfidence))%").monospacedDigit().frame(width: 40)
                    }
                }
                HStack {
                    Button("Save") { save() }
                    Button("Test Connection") { test() }.disabled(testing || accessKeyId.isEmpty || secret.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button("Remove Keys", role: .destructive) {
                        AWSSettings.credentials = nil
                        accessKeyId = ""; secret = ""; testResult = "Keys removed."
                    }
                }
            } header: {
                Text("Celebrity names (Amazon Rekognition)")
            } footer: {
                Text("Used only when you click Suggest Names. A head-and-shoulders crop of up to 3 faces per unnamed group is sent to Amazon — never whole photos or videos. About $1 per 1,000 faces; each face is looked up only once. Keys are stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }

    func save() {
        AWSSettings.credentials = AWSCredentials(accessKeyId: accessKeyId.trimmingCharacters(in: .whitespaces),
                                                 secretAccessKey: secret.trimmingCharacters(in: .whitespaces))
        AWSSettings.region = region
        AWSSettings.minConfidence = minConfidence
        testResult = "Saved."
    }

    /// Sends a tiny blank image: auth errors mean bad keys; "invalid image" means the keys work (and isn't billed).
    func test() {
        save()
        guard let client = AWSSettings.client else { return }
        testing = true
        testResult = nil
        Task {
            let blank = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { r in
                NSColor.gray.setFill(); r.fill(); return true
            }
            let jpeg = blank.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [:]) } ?? Data()
            do {
                _ = try await client.recognizeCelebrities(jpeg: jpeg)
                testResult = "Connected ✓"
            } catch let e as AWSError where e.type.contains("InvalidImage") || e.type.contains("InvalidParameter") {
                testResult = "Connected ✓"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

/// Looks up unnamed groups with Rekognition, then lets the user accept names.
struct CelebritySheet: View {
    @EnvironmentObject var model: FaceGroupingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var plan: (personIds: [Int64], newLookups: Int)?
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var suggestions: [CelebritySuggestion]?
    @State private var accepted: Set<Int64> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggest Celebrity Names").font(.title2.bold())
            if AWSSettings.client == nil {
                Text("Add your Amazon Rekognition keys in Settings first.")
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Open Settings") { openSettings(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else if let suggestions {
                results(suggestions)
            } else {
                intro
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            guard let namer else { return }
            let project = model.currentProject
            plan = await Task.detached { try? namer.plan(project: project) }.value
        }
    }

    var namer: CelebrityNamer? {
        guard let store = model.store, let client = AWSSettings.client else { return nil }
        let n = CelebrityNamer(store: store, client: client)
        n.minConfidence = AWSSettings.minConfidence
        return n
    }

    @ViewBuilder
    var intro: some View {
        if let plan {
            Text("\(plan.personIds.count) unnamed groups. \(plan.newLookups) faces will be sent to Amazon Rekognition (about $\(String(format: "%.2f", Double(plan.newLookups) * 0.001))); faces looked up before are free.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Rekognition knows many international celebrities; coverage of Vietnamese artists varies. Groups it doesn't know stay unnamed — name them yourself or add them to a Known-People folder.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView()
        }
        if running {
            ProgressView(value: Double(progress.0), total: Double(max(1, progress.1)))
            Text("Looked up \(progress.0) of \(progress.1)").font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Look Up") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(running || (plan?.personIds.isEmpty ?? true))
        }
    }

    func results(_ list: [CelebritySuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if list.isEmpty {
                Text("No celebrities recognised among these groups.")
            } else {
                Text("Tick the names to apply. Strong matches (several faces agree) are ticked already.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(list) { s in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { accepted.contains(s.personId) },
                                                         set: { if $0 { accepted.insert(s.personId) } else { accepted.remove(s.personId) } }))
                                    .labelsHidden()
                                FaceImage(faceId: model.people.first { $0.id == s.personId }?.coverFaceId, side: 48)
                                    .clipShape(Circle())
                                VStack(alignment: .leading) {
                                    Text(s.name).font(.headline)
                                    Text(String(format: "%.1f%% · %d of %d faces agree", s.confidence, s.votes, s.asked))
                                        .font(.caption).foregroundStyle(s.isStrong ? .secondary : Color.orange)
                                }
                                Spacer()
                                if let link = s.urls.first, let url = URL(string: link.hasPrefix("http") ? link : "https://\(link)") {
                                    Link("Profile", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if !list.isEmpty {
                    Button("Apply \(accepted.count) Names") {
                        for s in list where accepted.contains(s.personId) { model.rename(s.personId, to: s.name) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(accepted.isEmpty)
                }
            }
        }
    }

    func run() {
        guard let namer, let plan else { return }
        running = true
        error = nil
        Task {
            do {
                let list = try await namer.suggest(personIds: plan.personIds) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
                accepted = Set(list.filter(\.isStrong).map(\.personId))
                suggestions = list
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
