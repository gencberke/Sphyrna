import Foundation
import Testing
@testable import LoomCore

@Suite struct CodexResumeSettingsTests {
    private let id = "00000000-0000-4000-8000-000000000001"
    private let cwd = "/private/tmp/loom-real/resume-settings-fixture"

    private func response(sandbox: JSONValue = .object(["type": .string("readOnly"), "networkAccess": .bool(false)]),
                          roots: JSONValue? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "thread": .object(["id": .string(id)]), "cwd": .string(cwd),
            "model": .string("native-choice"), "reasoningEffort": .string("high"),
            "sandbox": sandbox, "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
            "activePermissionProfile": .null,
        ]
        value["runtimeWorkspaceRoots"] = roots
        return .object(value)
    }

    @Test func nativeCurrentWorkspaceDoesNotCountAsAnAdditionalRoot() throws {
        let decoded = try CodexResumeSettings.decodeNative(response(roots: .array([.string(cwd)])),
            threadID: id, workingDirectory: cwd)
        #expect(decoded.mode == .askBeforeEdits)
        #expect(decoded.model == "native-choice" && decoded.effort == "high")
    }

    @Test func documentedAbsentSandboxDefaultsRemainRestricted() throws {
        for type in ["readOnly", "workspaceWrite"] {
            let decoded = try CodexResumeSettings.decodeNative(response(sandbox: .object(["type": .string(type)])),
                threadID: id, workingDirectory: cwd)
            #expect(decoded.mode == (type == "readOnly" ? .askBeforeEdits : .acceptEdits))
        }
    }

    @Test func broaderOrMalformedNativeEvidenceIsRefused() {
        let candidates: [JSONValue] = [
            response(roots: .array([.string("/private/tmp/loom-real/another-workspace")])),
            response(roots: .null), response(roots: .string(cwd)),
            response(roots: .array([.string(cwd), .string("/outside")])),
            response(sandbox: .object(["type": .string("readOnly"), "networkAccess": .bool(true)])),
            response(sandbox: .object(["type": .string("readOnly"), "networkAccess": .null])),
            response(sandbox: .object(["type": .string("readOnly"), "networkAccess": .number(0)])),
            response(sandbox: .object(["type": .string("workspaceWrite"), "networkAccess": .bool(false),
                                      "writableRoots": .array([.string("/outside")])])),
            response(sandbox: .object(["type": .string("dangerFullAccess")])),
        ]
        for candidate in candidates {
            #expect(throws: (any Error).self) {
                try CodexResumeSettings.decodeNative(candidate, threadID: id, workingDirectory: cwd)
            }
        }
    }
}
