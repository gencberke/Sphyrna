import Darwin
import Foundation
import Testing
@testable import LoomCore

private struct OpenCodeProfileFixture {
    let context: RuntimeContext
    let executable: URL
    let roots: OpenCodeProfileRoots
    let resolvedRoots: OpenCodeProfileRoots
    let environment: [String: String]

    static func make(configSymlink: Bool = false, createAtProbe: Bool = false) async throws -> Self {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        let base = URL(fileURLWithPath: realPath(context.root), isDirectory: true)
        let home = base.appendingPathComponent("profile-home").path
        let data = base.appendingPathComponent("profile-data").path
        let cache = base.appendingPathComponent("profile-cache").path
        let configTarget = base.appendingPathComponent("profile-config").path
        let config = configSymlink ? base.appendingPathComponent("profile-config-link").path : configTarget
        let state = base.appendingPathComponent("profile-state").path
        let tmp = base.appendingPathComponent("profile-tmp").path
        let bin = cache + "/bin", log = data + "/log", repos = data + "/repos"
        for path in [home, data, cache, configTarget, state, bin, log, repos] + (createAtProbe ? [] : [tmp]) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if configSymlink { try FileManager.default.createSymbolicLink(atPath: config, withDestinationPath: configTarget) }
        let roots = OpenCodeProfileRoots(home: home, data: data, cache: cache, config: config, state: state,
                                         tmp: tmp, bin: bin, log: log, repos: repos, db: data + "/opencode.db")
        let resolvedRoots = OpenCodeProfileRoots(home: home, data: data, cache: cache, config: configTarget, state: state,
                                                 tmp: tmp, bin: bin, log: log, repos: repos, db: data + "/opencode.db")
        let script = base.appendingPathComponent("profile-fake")
        let source = """
            #!/bin/sh
            if [ "$1" != debug ] || [ "$2" != paths ] || [ "$#" != 2 ]; then exit 3; fi
            if [ -n "$FAKE_PROFILE_PID" ]; then echo "$$" > "$FAKE_PROFILE_PID"; fi
            if [ -n "$FAKE_PROFILE_CREATE" ]; then /bin/mkdir -p "$FAKE_PROFILE_CREATE"; fi
            if [ "$FAKE_PROFILE_SLOW" = 1 ]; then exec /bin/sleep 30; fi
            printf '%s' "$FAKE_PROFILE_OUTPUT"
            """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let output = outputFor(roots)
        var environment = ["PATH": "/usr/bin:/bin", "HOME": home, "FAKE_PROFILE_OUTPUT": output]
        if createAtProbe { environment["FAKE_PROFILE_CREATE"] = tmp }
        return Self(context: context, executable: script, roots: roots, resolvedRoots: resolvedRoots, environment: environment)
    }

    static func outputFor(_ roots: OpenCodeProfileRoots) -> String {
        ["home": roots.home, "data": roots.data, "cache": roots.cache, "config": roots.config,
         "state": roots.state, "tmp": roots.tmp, "bin": roots.bin, "log": roots.log,
         "repos": roots.repos, "db": roots.db].sorted { $0.key < $1.key }
            .map { "\($0.key.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.value)\n" }.joined()
    }

    func acquire(environment: [String: String]? = nil, timeout: Double = 5) async throws -> OpenCodeProfileProof {
        try await OpenCodeProfileProof.acquire(supervisor: context.supervisor, executable: executable.path,
                                               environment: environment ?? self.environment,
                                               workingDirectory: context.home.path, expected: roots, expectedResolved: resolvedRoots, timeout: timeout)
    }

    func close() async {
        _ = await context.runtime.shutdown()
        context.cleanup()
    }
}

private actor OpenCodeProfileHTTPFixture {
    let temporaryDirectory: String
    let workingDirectory: String
    private(set) var paths: [String] = []
    init(temporaryDirectory: String, workingDirectory: String) {
        self.temporaryDirectory = temporaryDirectory; self.workingDirectory = workingDirectory
    }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        let body: [String: Any]
        switch url.path {
        case "/api/info":
            body = ["pid": 1234, "version": "2.2.0", "urls": ["http://127.0.0.1:43123"],
                    "paths": ["tmp": temporaryDirectory]]
        default:
            body = ["data": ["id": "ses_fixture", "location": ["directory": workingDirectory]]]
        }
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct OpenCodeProfileProofTests {
    @Test func exactLayoutIsBoundToEnvironmentExecutableAndLaterDatabaseCreation() async throws {
        let fixture = try await OpenCodeProfileFixture.make(createAtProbe: true)
        do {
            let proof = try await fixture.acquire()
            #expect(proof.roots == fixture.roots)
            try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                     workingDirectory: fixture.context.home.path)
            try Data().write(to: URL(fileURLWithPath: fixture.roots.db))
            try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                     workingDirectory: fixture.context.home.path)
            let outside = fixture.context.root.appendingPathComponent("unexpected-db").path
            try Data().write(to: URL(fileURLWithPath: outside))
            try FileManager.default.removeItem(atPath: fixture.roots.db)
            try FileManager.default.createSymbolicLink(atPath: fixture.roots.db, withDestinationPath: outside)
            await #expect(throws: (any Error).self) {
                try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                         workingDirectory: fixture.context.home.path)
            }
            try FileManager.default.removeItem(atPath: fixture.roots.db)
            try Data().write(to: URL(fileURLWithPath: fixture.roots.db))
            var changed = fixture.environment
            changed["XDG_DATA_HOME"] = "/different"
            await #expect(throws: (any Error).self) {
                try await proof.validate(executable: fixture.executable.path, environment: changed,
                                         workingDirectory: fixture.context.home.path)
            }
            try "#!/bin/sh\nexit 9\n".write(to: fixture.executable, atomically: true, encoding: .utf8)
            await #expect(throws: (any Error).self) {
                try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                         workingDirectory: fixture.context.home.path)
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func mismatchedDuplicateAndTruncatedOutputNeverProduceProof() async throws {
        let fixture = try await OpenCodeProfileFixture.make()
        let output = OpenCodeProfileFixture.outputFor(fixture.roots)
        for value in [output.replacingOccurrences(of: fixture.roots.config, with: "/tmp/other"),
                      output + "home       /tmp/duplicate\n", String(output.dropLast())] {
            var environment = fixture.environment
            environment["FAKE_PROFILE_OUTPUT"] = value
            await #expect(throws: (any Error).self) { _ = try await fixture.acquire(environment: environment) }
        }
        #expect((await fixture.context.supervisor.ledgerSnapshot().scopes ?? []).isEmpty)
        await fixture.close()
    }

    @Test func ordinarySymlinkIsAllowedButRetargetingRevokesProof() async throws {
        let fixture = try await OpenCodeProfileFixture.make(configSymlink: true)
        do {
            let proof = try await fixture.acquire()
            try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                     workingDirectory: fixture.context.home.path)
            let replacement = fixture.context.root.appendingPathComponent("other-profile").path
            try FileManager.default.createDirectory(atPath: replacement, withIntermediateDirectories: true)
            try FileManager.default.removeItem(atPath: fixture.roots.config)
            try FileManager.default.createSymbolicLink(atPath: fixture.roots.config, withDestinationPath: replacement)
            await #expect(throws: (any Error).self) {
                try await proof.validate(executable: fixture.executable.path, environment: fixture.environment,
                                         workingDirectory: fixture.context.home.path)
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func cancellationRejectsProofAndReapsTheFakeHelper() async throws {
        let fixture = try await OpenCodeProfileFixture.make()
        let pidFile = fixture.context.root.appendingPathComponent("profile-helper-pid")
        var environment = fixture.environment
        environment["FAKE_PROFILE_PID"] = pidFile.path
        environment["FAKE_PROFILE_SLOW"] = "1"
        let selectedEnvironment = environment
        let call = Task { try await fixture.acquire(environment: selectedEnvironment, timeout: 2) }
        guard await SessionRuntimeTests.waitUntil(5, { FileManager.default.fileExists(atPath: pidFile.path) }) else {
            call.cancel()
            _ = try? await call.value
            await fixture.close()
            Issue.record("fake helper did not start")
            return
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        call.cancel()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(await SessionRuntimeTests.waitUntil(2) { ProcessTable.record(pid: pid).map(\.zombie) ?? true })
        #expect((await fixture.context.supervisor.ledgerSnapshot().scopes ?? []).isEmpty)
        await fixture.close()
    }

    @Test func unscopedSupervisorCannotProveOwnership() async throws {
        let fixture = try await OpenCodeProfileFixture.make()
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        await #expect(throws: (any Error).self) {
            _ = try await OpenCodeProfileProof.acquire(supervisor: supervisor, executable: fixture.executable.path,
                                                       environment: fixture.environment, workingDirectory: fixture.context.home.path,
                                                       expected: fixture.roots, expectedResolved: fixture.resolvedRoots, timeout: 2)
        }
        #expect((await supervisor.shutdown()).succeeded)
        await fixture.close()
    }
    @Test func changedProfilePreventsCreateResumeInputAndTerminalAttachment() async throws {
        let fixture = try await OpenCodeProfileFixture.make(configSymlink: true)
        do {
            let proof = try await fixture.acquire()
            let http = OpenCodeProfileHTTPFixture(temporaryDirectory: fixture.roots.tmp, workingDirectory: fixture.context.home.path)
            let url = URL(string: "http://127.0.0.1:43123")!
            let selected = OpenCodeClient(base: url, password: "fixture", profileProof: proof,
                                          executable: fixture.executable.path, environment: fixture.environment,
                                          workingDirectory: fixture.context.home.path) { try await http.respond($0) }
            let other = OpenCodeClient(base: url, password: "fixture", profileProof: proof,
                                       executable: fixture.executable.path, environment: fixture.environment,
                                       workingDirectory: fixture.context.home.path) { try await http.respond($0) }
            try await selected.verify(pid: 1234, version: "2.2.0", temporaryDirectory: fixture.roots.tmp)
            await #expect(throws: OpenCodeError.invalidTarget) {
                try await other.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/other")
            }
            try await other.verify(pid: 1234, version: "2.2.0", temporaryDirectory: fixture.roots.tmp)
            await #expect(throws: OpenCodeError.invalidTarget) {
                _ = try await other.create(directory: "/other", model: nil)
            }
            _ = try await selected.resume(id: "ses_fixture", directory: fixture.context.home.path)
            var changedEnvironment = fixture.environment
            changedEnvironment["XDG_DATA_HOME"] = "/different"
            await #expect(throws: OpenCodeProfileError.changed) {
                _ = try await selected.terminalProfile(directory: fixture.context.home.path, environment: changedEnvironment)
            }
            let replacement = fixture.context.root.appendingPathComponent("other-profile").path
            try FileManager.default.createDirectory(atPath: replacement, withIntermediateDirectories: true)
            try FileManager.default.removeItem(atPath: fixture.roots.config)
            try FileManager.default.createSymbolicLink(atPath: fixture.roots.config, withDestinationPath: replacement)
            await #expect(throws: OpenCodeProfileError.changed) {
                _ = try await selected.terminalProfile(directory: fixture.context.home.path, environment: fixture.environment)
            }
            await #expect(throws: OpenCodeProfileError.changed) {
                _ = try await selected.firstInput(sessionID: "ses_fixture", messageID: "msg_one", text: "approved")
            }
            await #expect(throws: OpenCodeProfileError.changed) {
                _ = try await other.create(directory: fixture.context.home.path, model: nil)
            }
            await #expect(throws: OpenCodeProfileError.changed) {
                _ = try await other.resume(id: "ses_fixture", directory: fixture.context.home.path)
            }
            #expect(await http.paths == ["/api/info", "/api/info", "/api/session/ses_fixture"])
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func rootOwnedProfileDirectoryIsNotClaimedForThisUser() async throws {
        guard geteuid() != 0 else { return }
        let fixture = try await OpenCodeProfileFixture.make()
        let roots = fixture.roots
        let unowned = OpenCodeProfileRoots(home: "/", data: roots.data, cache: roots.cache, config: roots.config,
                                           state: roots.state, tmp: roots.tmp, bin: roots.bin, log: roots.log,
                                           repos: roots.repos, db: roots.db)
        var environment = fixture.environment
        environment["FAKE_PROFILE_OUTPUT"] = OpenCodeProfileFixture.outputFor(unowned)
        await #expect(throws: OpenCodeProfileError.unowned) {
            _ = try await OpenCodeProfileProof.acquire(supervisor: fixture.context.supervisor, executable: fixture.executable.path,
                                                       environment: environment, workingDirectory: fixture.context.home.path,
                                                       expected: unowned, expectedResolved: OpenCodeProfileRoots(
                                                        home: "/", data: fixture.resolvedRoots.data, cache: fixture.resolvedRoots.cache,
                                                        config: fixture.resolvedRoots.config, state: fixture.resolvedRoots.state,
                                                        tmp: fixture.resolvedRoots.tmp, bin: fixture.resolvedRoots.bin, log: fixture.resolvedRoots.log,
                                                        repos: fixture.resolvedRoots.repos, db: fixture.resolvedRoots.db), timeout: 5)
        }
        await fixture.close()
    }

    @Test func changingExecutableSymlinkInvalidatesTheProof() async throws {
        let fixture = try await OpenCodeProfileFixture.make()
        do {
            let link = fixture.context.root.appendingPathComponent("profile-link").path
            let replacement = fixture.context.root.appendingPathComponent("other-profile-fake").path
            try FileManager.default.copyItem(atPath: fixture.executable.path, toPath: replacement)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.executable.path)
            let proof = try await OpenCodeProfileProof.acquire(supervisor: fixture.context.supervisor, executable: link,
                                                               environment: fixture.environment, workingDirectory: fixture.context.home.path,
                                                               expected: fixture.roots, expectedResolved: fixture.resolvedRoots)
            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: replacement)
            await #expect(throws: (any Error).self) {
                try await proof.validate(executable: link, environment: fixture.environment,
                                         workingDirectory: fixture.context.home.path)
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func anAlreadyRetargetedSymlinkCannotEscapeTheExpectedResolvedLayout() async throws {
        let fixture = try await OpenCodeProfileFixture.make(configSymlink: true)
        let replacement = fixture.context.root.appendingPathComponent("unexpected-profile").path
        try FileManager.default.createDirectory(atPath: replacement, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: fixture.roots.config)
        try FileManager.default.createSymbolicLink(atPath: fixture.roots.config, withDestinationPath: replacement)
        await #expect(throws: OpenCodeProfileError.unexpectedRoots) { _ = try await fixture.acquire() }
        #expect((await fixture.context.supervisor.ledgerSnapshot().scopes ?? []).isEmpty)
        await fixture.close()
    }

}
