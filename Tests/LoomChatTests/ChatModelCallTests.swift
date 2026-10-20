import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// G5 and F1 of the cost-and-context rule (goal 3 of D-83): Sphyrna causes a model call on the user's subscription only for what
// the user sends, asks or approves, and for one call of its own, a Chat session's title (one per card, at most three tries, on
// at most 2,000 characters of the first message). The requests that call a model are a named set in code; a session's whole life
// on the fake provider makes exactly one of them per card.

/// Checks that `capped` is `text` in the CLI's shape: the first 1,500 characters, ` [… N characters omitted …] `, the tail, 2,000
/// characters in all, and N is what was left out.
private func isTheCliCut(_ capped: String, of text: String, _ label: Comment) {
    #expect(capped.count == 2_000, label)
    guard let open = capped.range(of: " [… "),
          let close = capped.range(of: " characters omitted …] ", range: open.upperBound..<capped.endIndex),
          let omitted = Int(capped[open.upperBound..<close.lowerBound]) else {
        Issue.record("no marker in the description: \(label)")
        return
    }
    let head = capped[..<open.lowerBound], tail = capped[close.upperBound...]
    #expect(head == text.prefix(1_500), label)
    #expect(tail == text.suffix(tail.count), label)
    #expect(omitted == text.count - head.count - tail.count, "the marker names \(omitted): \(label)")
}

struct ChatModelCallSetTests {
    /// Every case of the enum, with what it costs. The switch has no default: a new request does not compile until it is
    /// decided here, and `modelCallSubtypes` is where a request that calls a model is named.
    private func costs(_ request: OutgoingControlRequest) -> Bool {
        switch request {
        case .generateSessionTitle, .sideQuestion: true
        case .interrupt, .setPermissionMode, .setModel, .applyFlagSettings, .getContextUsage, .getUsage, .initialize,
             .cancelAsyncMessage, .backgroundTasks, .rewindFiles, .rewindConversation, .other: false
        }
    }

    @Test func theRequestsThatCallAModelAreTheTitleAndTheQuickQuestionOnly() {
        #expect(OutgoingControlRequest.modelCallSubtypes == ["generate_session_title", "side_question"])
        let all: [OutgoingControlRequest] = [
            .interrupt(cancelQueued: true), .setPermissionMode(.plan), .setModel("haiku"),
            .applyFlagSettings(.effortLevel("low")), .getContextUsage(.summary), .getUsage(skipBehaviors: true), .initialize,
            .cancelAsyncMessage(messageUUID: "u"), .backgroundTasks(toolUseID: nil), .rewindFiles(userMessageID: "u", dryRun: true),
            .rewindConversation(targetMessageUUID: "u"), .sideQuestion("why?"), .generateSessionTitle(description: "a message"),
            .other(subtype: "mcp_status", fields: [:]),
        ]
        for request in all {
            #expect(request.costsAModelCall == costs(request), Comment(rawValue: request.subtype))
        }
        #expect(all.filter(\.costsAModelCall).map(\.subtype).sorted() == ["generate_session_title", "side_question"])
        // A subtype sent by name is judged by the name.
        #expect(OutgoingControlRequest.other(subtype: "side_question", fields: [:]).costsAModelCall)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatModelCallTests {
    /// The requests a Chat session makes in its life, none of which calls a model.
    private static let localRequests: Set<String> = [
        "initialize", "interrupt", "set_permission_mode", "set_model", "apply_flag_settings", "list_permission_rules",
        "get_context_usage", "cancel_async_message", "background_tasks", "rewind_files", "rewind_conversation", "stop_task",
    ]

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func logs() -> (requests: URL, titles: URL) {
        let folder = FileManager.default.temporaryDirectory
        return (folder.appendingPathComponent("loom-requests-\(UUID()).log"), folder.appendingPathComponent("loom-titles-\(UUID()).log"))
    }

    /// A card's title is the one model call Sphyrna makes by itself.
    @Test func aChatSessionsWholeLifeMakesOneModelCallPerCardAndItIsTheTitle() async throws {
        let (requests, titles) = logs()
        defer { for url in [requests, titles] { try? FileManager.default.removeItem(at: url) } }
        let rig = try await Rig.make(environment: [
            "LOOM_FAKE_CHAT_REQUEST_LOG": requests.path, "LOOM_FAKE_CHAT_TITLE_LOG": titles.path,
        ])
        let first = UUID()
        let driver = rig.driver(first)
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        // Two messages, a mode change, Ask on and off, a model and an effort pick.
        try await driver.send("Explain how a binary search works")
        #expect(await idle(driver))
        try await driver.send("And when does it not apply?")
        #expect(await idle(driver))
        try await driver.setPermissionMode("acceptEdits")
        try await driver.setPermissionMode("ask")
        try await driver.setPermissionMode("default")
        try await driver.setModel("claude-fake-5-1")
        try await driver.setEffort("high")
        // A stop and a message that resumes the session in a new process.
        _ = try await driver.stop()
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        try await driver.send("Back again, one more question")
        #expect(await idle(driver))
        // `/clear` moves the run to a new card; a message there is that card's first.
        try await driver.send("/clear")
        #expect(await waitUntil { await driver.sessionID != first })
        #expect(await idle(driver))
        try await driver.send("A fresh start on another topic")
        #expect(await idle(driver))
        #expect(await waitUntil { lines(titles).count >= 2 })
        try await Task.sleep(for: .milliseconds(500))

        let subtypes = lines(requests)
        let modelCalls = subtypes.filter { OutgoingControlRequest.modelCallSubtypes.contains($0) }
        #expect(modelCalls == ["generate_session_title", "generate_session_title"], "\(subtypes)")
        #expect(lines(titles).count == 2, "one title per card: \(lines(titles))")
        // Everything else the session asked of the CLI is local, and a request nobody has named fails here.
        let unknown = Set(subtypes).subtracting(Self.localRequests).subtracting(OutgoingControlRequest.modelCallSubtypes)
        #expect(unknown.isEmpty, "\(unknown.sorted()) of \(subtypes)")
        #expect(subtypes.contains("initialize") && subtypes.contains("set_permission_mode"), "the log saw the session: \(subtypes)")
        await rig.finish()
    }

    /// F1: the title is asked for from the opening of the message, at most 2,000 characters, in the CLI's own shape.
    @Test func aLongFirstMessageSendsAtMost2000CharactersToTheTitleCall() async throws {
        let (_, titles) = logs()
        defer { try? FileManager.default.removeItem(at: titles) }
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_TITLE_LOG": titles.path])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        let message = (0..<10_000).map { index in String(UnicodeScalar(UInt8(97 + index % 26))) }.joined()
        try await driver.send(message)
        #expect(await waitUntil { lines(titles).count == 1 })
        let line = try #require(lines(titles).first)
        let json = try #require(line.split(separator: " ", maxSplits: 1).last)
        let logged = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let description = try #require(logged["description"] as? String)
        #expect(logged["length"] as? Int == 2_000, "the fake saw \(description.count) characters")
        isTheCliCut(description, of: message, "10,000 characters")
        #expect(await idle(driver))
        await rig.finish()
    }

    @Test func aMessageUpTo2000CharactersIsSentWhole() async throws {
        let (_, titles) = logs()
        defer { try? FileManager.default.removeItem(at: titles) }
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_TITLE_LOG": titles.path])
        let driver = rig.driver()
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(firstMessage: ""))
        let message = String(repeating: "word ", count: 399) + "last."
        #expect(message.count == 2_000)
        try await driver.send(message)
        #expect(await waitUntil { lines(titles).count == 1 })
        let json = try #require(lines(titles).first?.split(separator: " ", maxSplits: 1).last)
        let logged = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(logged["description"] as? String == message)
        await rig.finish()
    }
}

struct ChatTitleDescriptionTests {
    @Test func theCutHasTheCliShapeAtAnyLength() {
        for count in [2_001, 2_050, 2_500, 11_000, 99_999, 128 * 1_024, 2_000_000] {
            let text = String((0..<count).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
            isTheCliCut(ChatTitleDescription.capped(text), of: text, "\(count) characters")
        }
        let short = String(repeating: "é", count: 2_000)
        #expect(ChatTitleDescription.capped(short) == short)
    }
}
