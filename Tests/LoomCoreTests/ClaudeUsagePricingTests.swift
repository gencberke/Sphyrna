import Darwin
import Foundation
import Testing
@testable import LoomCore

@Suite struct ClaudeUsagePricingTests {
    @Test func haikuReferenceMessageReproducesTheCliCost() throws {
        // 916 in, 84 out, 23,482 cache reads and 9,303 1-hour writes at Haiku 4.5 rates, from the
        // planning scan's cost-state cross-check: 916 + 420 + 2,348.2 + 18,606 = 22,290.2 per million.
        let tokens = UsageTokens(input: 916, output: 84, cacheWrite1h: 9_303, cacheRead: 23_482)
        let cost = UsagePricing.costUSD(model: "claude-haiku-4-5-20251001", tokens: tokens, fast: false, usGeo: false)
        #expect(abs(try #require(cost) - 0.0222902) < 1e-10)
    }

    @Test func cacheReadMultipliersDifferByModel() throws {
        let million = UsageTokens(cacheRead: 1_000_000)
        func read(_ model: String) throws -> Double {
            try #require(UsagePricing.costUSD(model: model, tokens: million, fast: false, usGeo: false))
        }
        #expect(abs(try read("claude-fable-5-1") - 0.25) < 1e-12)
        #expect(abs(try read("claude-fable-5") - 1.0) < 1e-12)
        #expect(abs(try read("claude-opus-5-5") - 0.20) < 1e-12)
        #expect(abs(try read("claude-opus-5") - 0.50) < 1e-12)
        #expect(abs(try read("claude-haiku-3-5") - 0.08) < 1e-12)
    }

    @Test func everyTableEntryHasTheDocumentedWritePrices() throws {
        // 5m write 1.25x and 1h write 2x of the base input price, per the pricing page rows.
        let fiveMinute = UsageTokens(cacheWrite5m: 1_000_000), oneHour = UsageTokens(cacheWrite1h: 1_000_000)
        let rows: [(String, Double, Double)] = [
            ("claude-fable-5-1", 12.5, 20), ("claude-opus-5-5", 5, 8), ("claude-opus-5", 6.25, 10),
            ("claude-opus-4-1", 18.75, 30), ("claude-sonnet-5-5", 2.5, 4), ("claude-sonnet-4-6", 3.75, 6),
            ("claude-haiku-4-5", 1.25, 2), ("claude-haiku-3-5", 1, 1.6),
        ]
        for (model, five, hour) in rows {
            #expect(abs(try #require(UsagePricing.costUSD(model: model, tokens: fiveMinute, fast: false, usGeo: false)) - five) < 1e-9)
            #expect(abs(try #require(UsagePricing.costUSD(model: model, tokens: oneHour, fast: false, usGeo: false)) - hour) < 1e-9)
        }
    }

    @Test func fastModeOnlyAppliesToModelsThatHaveIt() throws {
        let million = UsageTokens(input: 1_000_000, output: 1_000_000)
        func cost(_ model: String, fast: Bool) throws -> Double {
            try #require(UsagePricing.costUSD(model: model, tokens: million, fast: fast, usGeo: false))
        }
        #expect(abs(try cost("claude-opus-5-5", fast: true) - 48) < 1e-9)
        #expect(abs(try cost("claude-opus-5", fast: true) - 60) < 1e-9)
        #expect(abs(try cost("claude-opus-4-8", fast: true) - 60) < 1e-9)
        #expect(abs(try cost("claude-opus-4-6", fast: true) - 30) < 1e-9) // runs at standard speed
        #expect(abs(try cost("claude-opus-5-5", fast: false) - 24) < 1e-9)
    }

    @Test func geoMultiplierSkipsModelsBefore46AndNeverScalesWebSearch() throws {
        let tokens = UsageTokens(input: 1_000_000, webSearches: 100)
        #expect(abs(try #require(UsagePricing.costUSD(model: "claude-sonnet-4-6", tokens: tokens, fast: false, usGeo: true)) - (3.3 + 1.0)) < 1e-9)
        #expect(abs(try #require(UsagePricing.costUSD(model: "claude-sonnet-4-5", tokens: tokens, fast: false, usGeo: true)) - (3.0 + 1.0)) < 1e-9)
    }

    @Test func modelIDsNormalize() {
        let id = UsagePricing.canonicalModelID
        #expect(id("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(id("Claude-Opus-4.5") == "claude-opus-4-5")
        #expect(id("claude-opus-4-1-20250805") == "claude-opus-4-1")
        #expect(id("claude-opus-4-20250514") == "claude-opus-4")
        #expect(id("claude-sonnet-4-6[1m]") == "claude-sonnet-4-6")
        #expect(id("anthropic/claude-sonnet-5-5") == "claude-sonnet-5-5")
        #expect(id("us.anthropic.claude-3-5-haiku-20241022-v1:0") == "claude-haiku-3-5")
        #expect(id("claude-sonnet-4-5@20250929") == "claude-sonnet-4-5")
        #expect(id("claude-3-5-haiku-latest") == "claude-haiku-3-5")
        #expect(UsagePricing.price(forModel: "claude-opus-5-5-20271010")?.displayName == "Opus 5.5")
        // No prefix guessing: a future minor version is unknown rather than priced as its sibling.
        #expect(UsagePricing.price(forModel: "claude-opus-4-9") == nil)
        #expect(UsagePricing.price(forModel: "opus") == nil)
        #expect(UsagePricing.price(forModel: "<synthetic>") == nil)
    }

    @Test func tableCarriesItsDate() {
        #expect(UsagePricing.asOf == "2026-10-07")
        #expect(UsagePricing.sourceURL.hasPrefix("https://platform.claude.com/"))
    }
}

@Suite struct ClaudeProfileLayoutTests {
    private let home = URL(fileURLWithPath: "/tmp/loom-layout-home", isDirectory: true)

    @Test func anExplicitProfileWinsOverTheEnvironment() {
        let layout = ClaudeProfileLayout(
            profileDirectory: URL(fileURLWithPath: "/tmp/loom-layout-profile"),
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/loom-layout-env"], home: home)
        #expect(layout.source == .explicitProfile)
        #expect(layout.configDirectory.path.hasSuffix("loom-layout-profile"))
        #expect(layout.projectsDirectory.path.hasSuffix("loom-layout-profile/projects"))
    }

    @Test func theEnvironmentComesBeforeTheHomeDefault() {
        let layout = ClaudeProfileLayout(profileDirectory: nil, environment: ["CLAUDE_CONFIG_DIR": "/tmp/loom-layout-env"], home: home)
        #expect(layout.source == .environment)
        #expect(layout.configDirectory.path.hasSuffix("loom-layout-env"))
    }

    @Test func theHomeDefaultIsDotClaudeAndNeverDotConfig() {
        let layout = ClaudeProfileLayout(profileDirectory: nil, environment: [:], home: home)
        #expect(layout.source == .homeDefault)
        #expect(layout.configDirectory.path.hasSuffix("loom-layout-home/.claude"))
        #expect(!layout.configDirectory.path.contains(".config"))
    }

    @Test func emptyOrRelativeEnvironmentValuesFallThroughToHome() {
        for value in ["", "relative/dir", "~/elsewhere"] {
            let layout = ClaudeProfileLayout(profileDirectory: nil, environment: ["CLAUDE_CONFIG_DIR": value], home: home)
            #expect(layout.source == .homeDefault)
        }
    }

    @Test func theConfigDirectoryIsResolvedThroughSymlinks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loom-layout-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ClaudeProfileLayout(profileDirectory: root.appendingPathComponent("link"), environment: [:], home: home)
        let real = try #require(realpath(root.appendingPathComponent("real").path, nil))
        defer { free(real) }
        #expect(layout.configDirectory.path == String(cString: real))
    }
}
