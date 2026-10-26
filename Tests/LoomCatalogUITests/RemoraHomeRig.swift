import Foundation
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

private final class RemoraHomeRigAnchor: NSObject {}

/// A catalog with sessions at chosen ages, a model over it and a Remora host on a temporary data root, for the Home tests. With
/// `fakeProvider` the host's calls run the fake provider's Remora mode (`LOOM_FAKE_REMORA_*` from `script`); without it a call would
/// run `/usr/bin/false`, and no test makes one. Nothing here touches the real `~/.claude`, `~/.codex` or a vault.
@MainActor
final class RemoraHomeRig {
    struct Seed {
        var title: String
        /// An index into the rig's projects.
        var project: Int
        /// How long ago the session was last active.
        var ago: TimeInterval
        var provider: ManagedSession.Provider = .claude
    }

    /// The rig's "now": today at noon, local time. Sessions, the kept brief and the host's clock all count from it, so the day's brief is
    /// today's whatever the hour the test runs at.
    let base: Date
    let root: URL
    let catalog: SessionCatalog
    let model: CatalogModel
    let supervisor: ProcessSupervisor
    private(set) var host: RemoraHost?
    private(set) var projects: [CatalogProject] = []
    private(set) var sessions: [UUID] = []
    var remoraDirectory: URL { root.appendingPathComponent("remora", isDirectory: true) }
    var pids: URL { root.appendingPathComponent("fake-pid") }
    var log: URL { root.appendingPathComponent("fake-log.json") }
    var ranAProcess: Bool { FileManager.default.fileExists(atPath: pids.path) || FileManager.default.fileExists(atPath: log.path) }

    init(base: Date, root: URL, catalog: SessionCatalog, model: CatalogModel, supervisor: ProcessSupervisor) {
        self.base = base
        self.root = root
        self.catalog = catalog
        self.model = model
        self.supervisor = supervisor
    }

    static func make(projectNames: [String] = ["loom"], seeds: [Seed], preferences: RemoraPreferences = RemoraPreferences(),
                     script: [String: String] = [:], withHost: Bool = true,
                     scriptFor: (([UUID]) -> [String: String])? = nil) async throws -> RemoraHomeRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let store = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(), preferences: store)
        model.branchReader = { _ in .unavailable }
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let rig = RemoraHomeRig(base: now, root: root, catalog: catalog, model: model,
                                supervisor: try ProcessSupervisor(ledger: OwnershipLedger()))
        for name in projectNames {
            let folder = root.appendingPathComponent("work-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            rig.projects.append(try await catalog.addProject(path: folder.path).project)
        }
        for seed in seeds {
            let project = rig.projects[seed.project]
            let id = UUID()
            let when = now.addingTimeInterval(-seed.ago)
            try await catalog.insertSession(ManagedSession(id: id, provider: seed.provider, workingDirectory: project.path), title: seed.title,
                                            createdAt: when.addingTimeInterval(-60), lastUsedAt: when, lifecycle: .idle,
                                            projectID: project.id, lastActivityAt: when)
            rig.sessions.append(id)
        }
        await model.start()
        await model.stopAndWait()
        await model.settle()
        model.remora.install(preferences: preferences, persist: { _ in })
        // `scriptFor` writes the fake's script with the seeded sessions' ids (an answer that names one of them).
        if withHost { rig.makeHost(seeds: seeds, preferences: preferences, script: scriptFor?(rig.sessions) ?? script, now: now) }
        return rig
    }

    /// Makes the host and installs it (`make` does unless `withHost` is false; a test installs it later to stand for the app,
    /// which shows Home before its runtime installs the host).
    func makeHost(seeds: [Seed], preferences: RemoraPreferences, script: [String: String], now: Date) {
        var built: [SessionSummary] = []
        var sessionProjects: [UUID: UUID] = [:]
        var names: [UUID: String] = [:]
        var recency: [(project: UUID?, activity: Date)] = []
        for (index, seed) in seeds.enumerated() {
            let project = projects[seed.project]
            let when = now.addingTimeInterval(-seed.ago)
            built.append(SessionSummary(id: sessions[index], harness: .claude, title: seed.title, projectID: project.id,
                                            projectName: project.name, state: .idle, face: nil, lastActivityAt: when))
            sessionProjects[sessions[index]] = project.id
            names[project.id] = project.name
            recency.append((project.id, when))
        }
        let summaries = built
        let maps = RemoraCatalogMaps(sessionProjects: sessionProjects, projectNames: names, recency: recency)
        var environment = ["LOOM_FAKE_REMORA_LOG": log.path, "LOOM_FAKE_PIDFILE": pids.path]
        environment.merge(script) { _, new in new }
        let supervisor = supervisor
        let work = remoraDirectory.appendingPathComponent("run")
        let fake = Bundle(for: RemoraHomeRigAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-fake-provider").path
        let extra = environment
        let created = RemoraHost(
            dataRoot: root, settings: preferences, sessions: { _ in summaries }, transcript: { _ in nil }, maps: { maps },
            makeCall: { usage in
                RemoraCall(supervisor: supervisor, executable: fake,
                           environment: RemoraCall.environment(from: ["PATH": "/usr/bin:/bin"], configDirectory: nil),
                           workingDirectory: work, usage: usage, questionDeadline: 20, briefDeadline: 20, terminationGrace: 1,
                           additionalEnvironment: extra)
            }, timeZone: .current, clock: { now })
        host = created
        model.installRemora(host: created)
    }

    /// Writes the day's kept brief where the host reads it (started `ago` seconds back). `nexts` carries each chip's "where
    /// to pick up" line.
    func keepBrief(text: String, chips: [(session: Int, why: String)], nexts: [Int: String] = [:],
                   drafts: [(session: Int, text: String)] = [], facts: [String] = [], ago: TimeInterval = 60,
                   footer: String = "read 3 sessions and 1 project note") throws {
        let brief = RemoraKeptBrief(
            startedAt: base.addingTimeInterval(-ago), text: text, cited: [],
            chips: chips.map { RemoraChip(sessionID: sessions[$0.session].uuidString, why: $0.why, next: nexts[$0.session] ?? "") },
            drafts: drafts.map { RemoraDraft(sessionID: sessions[$0.session].uuidString, text: $0.text) },
            proposedFacts: facts, readSessionIDs: sessions, footer: footer)
        try RemoraKeptBriefFile(directory: remoraDirectory).write(brief)
    }

    func finish() async {
        model.stop()
        _ = await supervisor.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
