import Foundation
import Testing
@testable import LoomCore

/// R3: what each harness may do per build identity. The production identity starts Claude only (D-28, D-69 (5)); the
/// development one starts Claude and Codex. Nothing here starts a run. D-94: the table is the one gate (the guard at the end).
struct HarnessCapabilitiesTests {
    private static let production: Set<ManagedSession.Provider> = [.claude]
    private static let development: Set<ManagedSession.Provider> = [.claude, .codex]

    /// Claude's row, with `startable` as the build says.
    private static func claude(startable: Bool) -> HarnessCapabilities {
        HarnessCapabilities(
            hasHarness: true, startable: startable, structuredFace: true, readsTranscript: true, sideChats: true,
            readsContext: true, readsEdits: true, subagents: true, rewind: true, quickQuestion: true, deletes: true,
            usageLimits: true, modelCatalog: true, reportsRunSettings: true, displayName: "Claude")
    }

    /// Codex's row: today's answers (nothing read, nothing deleted), plus the two a later package reads.
    private static func codex(startable: Bool) -> HarnessCapabilities {
        HarnessCapabilities(
            hasHarness: true, startable: startable, structuredFace: false, readsTranscript: false, sideChats: false,
            readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
            usageLimits: true, modelCatalog: true, reportsRunSettings: false, displayName: "Codex")
    }

    @Test func claudeHasEverythingAndIsStartableWhereTheBuildSaysSo() {
        #expect(HarnessCapabilities.of(.claude, startable: Self.production) == Self.claude(startable: true))
        #expect(HarnessCapabilities.of(.claude, startable: Self.development) == Self.claude(startable: true))
        // A build that cannot start Claude keeps the rest: the sessions are listed and read, not started or resumed.
        #expect(HarnessCapabilities.of(.claude, startable: [.codex]) == Self.claude(startable: false))
    }

    @Test func codexIsStartableOnlyWhereTheBuildSaysSoAndReadsNothing() {
        #expect(HarnessCapabilities.of(.codex, startable: Self.production) == Self.codex(startable: false))
        #expect(HarnessCapabilities.of(.codex, startable: Self.development) == Self.codex(startable: true))
    }

    @Test func aSyntheticSessionHasNothingInAnyBuild() {
        let nothing = HarnessCapabilities(
            hasHarness: false, startable: false, structuredFace: false, readsTranscript: false, sideChats: false,
            readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
            usageLimits: false, modelCatalog: false, reportsRunSettings: false, displayName: "Synthetic")
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.production) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.development) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: [.synthetic]) == nothing)
    }

    @Test func theIntrinsicAnswerIsTheTableWithNothingStartable() {
        #expect(HarnessCapabilities.intrinsic(of: .claude) == Self.claude(startable: false))
        #expect(HarnessCapabilities.intrinsic(of: .codex) == Self.codex(startable: false))
        #expect(SessionHarness.claude.capabilities == HarnessCapabilities.intrinsic(of: .claude))
        #expect(SessionHarness.codex.capabilities == HarnessCapabilities.intrinsic(of: .codex))
    }

    @Test func aPlainNewSessionStartsClaude() {
        #expect(ManagedSession.Provider.newSessionDefault == .claude)
    }

    // MARK: The guard (D-94)

    /// The files that dispatch per harness on purpose: a launch profile built for one harness, and the evidence tooling's
    /// choice of the harness to fake. No other file asks which harness a session has; it asks the table or the descriptor.
    /// (The usage page's ask cadence reads the catalogue since C2, so `UsageModel.swift` is not here.)
    private static let dispatchFiles: Set<String> = [
        "Sources/LoomCore/ProviderResume.swift",
        "Sources/loom-app/Evidence/AppDelegate+Evidence.swift",
        "Sources/loom-app/Evidence/EvidenceCatalogCommands.swift",
    ]

    /// The files that define the catalogue itself: the ids are their values there, not a gate's question.
    private static let descriptorFiles: Set<String> = [
        "Sources/LoomCore/HarnessID.swift",
        "Sources/LoomCore/HarnessDescriptor.swift",
        "Sources/LoomCore/HarnessCatalogue.swift",
    ]

    /// A comparison with a harness id (`provider == .claude`, `harness != .opencode`), or a `? "codex" : "claude"` name
    /// ternary, not a mention in a comment or a case label.
    static func asksWhichHarness(_ line: String) -> Bool {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//") else { return false }
        let comparison = #"(==|!=)\s*\.(claude|codex|opencode|agy|pi)\b(?!\w)|\.(claude|codex|opencode|agy|pi)\s*(==|!=)"#
        let ternary = #"\?\s*"(claude|codex|opencode|agy|pi)"\s*:\s*""#
        return code.range(of: comparison, options: .regularExpression) != nil
            || code.range(of: ternary, options: .regularExpression) != nil
    }

    @Test func theMatcherSeesAComparisonOrATernaryAndNothingElse() {
        #expect(Self.asksWhichHarness("guard record.session.provider == .claude else { return }"))
        #expect(Self.asksWhichHarness("if summary.harness != .opencode {"))
        #expect(Self.asksWhichHarness("filter { $0.harness == .agy }"))
        #expect(Self.asksWhichHarness("let isPi = harnessID == .pi"))
        #expect(Self.asksWhichHarness(#"let name = provider == .codex ? "codex" : "claude""#))
        #expect(Self.asksWhichHarness(#"let command = isAgy ? "agy" : "pi""#))
        #expect(!Self.asksWhichHarness("/// The UI asks these, never `provider == .claude`"))
        #expect(!Self.asksWhichHarness("case .claude: self = .claude"))
        #expect(!Self.asksWhichHarness("var pick = modePick == .claudeDefault ? .inherit : modePick"))
        #expect(!Self.asksWhichHarness(#"let mark = "harness-codex""#))
        #expect(!Self.asksWhichHarness("canStart(.newSessionDefault, projectID: nil)"))
    }

    @Test func noFileOutsideTheDescriptorAndDispatchFilesAsksWhichHarnessItHas() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let path = String(url.path.dropFirst(repoRoot.path.count + 1))
            // The probe is a developer tool that runs one named harness.
            guard !Self.dispatchFiles.contains(path), !Self.descriptorFiles.contains(path),
                  !path.hasPrefix("Sources/loom-probe/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.asksWhichHarness(String(line)) {
                offenders.append("\(path):\(index + 1)")
            }
        }
        #expect(scanned > 100, "the walk found the sources")
        #expect(offenders.isEmpty, "ask HarnessCatalogue, not the harness: \(offenders)")
    }
}
