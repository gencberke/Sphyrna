import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

// V22 part 2: what a side chat answers on its own. The classifier is a pure function over a command line; the policy maps a
// tool request to ask / allow / deny. Both are table tests: a line that changes anything must be refused, and a harmless
// line must not cost the user a card.

private func request(_ tool: String, _ input: JSONValue, agent: String? = nil) -> ToolPermissionRequest {
    var fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input,
                                       "tool_use_id": "toolu_1"]
    if let agent { fields["agent_id"] = .string(agent) }
    return ToolPermissionRequest(json: .object(fields))!
}

struct ReadOnlyCommandTests {
    @Test(arguments: [
        "ls", "ls -la src", "cat a.txt", "head -n 5 a | wc -l", "grep -rn foo src | head -20", "rg foo", "pwd",
        "ls 2>/dev/null", "ls > /dev/null", "ls &>/dev/null", "ls 2>&1 | head", "find . -name '*.swift' -type f",
        "git status", "git diff --stat", "git log --oneline -n 5", "git -C sub status", "git --no-pager show HEAD",
        "git branch --list", "git branch -a", "git branch --show-current", "git config --get user.name", "git remote -v",
        "sort a b", "tail -n 20 log", "echo 'a; rm b'", "echo \"a && b\"", "uniq a", "date", "file a", "jq .a x.json",
    ])
    func provenReadOnly(_ command: String) {
        #expect(ReadOnlyCommand.isReadOnly(command), "\(command) should be read-only")
    }

    @Test(arguments: [
        // Writing redirections.
        "ls > x", "ls >> x", "echo hi > y.txt", "cat a > b", "ls 2> err", "ls &> out", "ls > /dev/nullx", "ls >| x", "cat < a",
        // Chaining, background, groups, substitution, expansion.
        "cat a; rm b", "ls && rm x", "ls || rm x", "ls & rm x", "ls\nrm x", "(rm x)", "{ rm x; }", "echo $(rm x)", "echo `rm x`",
        "echo \"$(rm x)\"", "cat <(ls)", "echo $HOME", "ls |& cat",
        // A leading assignment, and programs outside the list.
        "FOO=1 ls", "rm x", "mv a b", "cp a b", "touch x", "mkdir d", "sed -i s/a/b/ x", "awk '{print}' x", "tee x", "xargs rm",
        "env ls", "sudo ls", "sh -c ls", "bash -c 'rm x'", "python3 -c 'print(1)'", "npm test", "curl http://example.com",
        // Flags that write, run or follow.
        "find . -delete", "find . -exec rm {} +", "find . -ok rm {} ;", "find . -fprint out", "sort -o x a", "sort --output=x a",
        "sort -ro x a", "tree -o out", "tail -f log", "tail -F log", "tail --follow log", "rg --pre ./x foo", "date -s 12:00",
        "uniq a b", "xxd a b", "file -C", "git diff --output=x", "git log --output x", "git commit -m x", "git checkout main",
        "git push", "git branch new", "git branch -d old", "git branch -D old", "git config user.name x", "git remote add o u",
        "git grep -O foo", "git stash", "git reset --hard", "git -c core.pager=x status", "git",
        // Unbalanced or empty input.
        "", "   ", "echo 'oops", "echo \"oops", "echo \\",
    ])
    func mayWrite(_ command: String) {
        #expect(!ReadOnlyCommand.isReadOnly(command), "\(command) must not be treated as read-only")
    }
}

struct SideChatPolicyTests {
    private let denied = ChatRequestDecision.deny(SideChatPolicy.editsRefused)

    @Test func editToolsAreDeniedByDefault() {
        let policy = SideChatPolicy()
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            #expect(policy.decide(request(tool, ["file_path": "/tmp/a"])) == denied, "\(tool)")
        }
    }

    @Test func bashIsDecidedByTheCommand() {
        let policy = SideChatPolicy()
        #expect(policy.decide(request("Bash", ["command": "ls -la"])) == .allow)
        #expect(policy.decide(request("Bash", ["command": "grep a b | head"])) == .allow)
        #expect(policy.decide(request("Bash", ["command": "echo hi > y.txt"])) == denied)
        #expect(policy.decide(request("Bash", ["command": "rm -rf build"])) == denied)
        // A request without a command is not provably harmless.
        #expect(policy.decide(request("Bash", [:])) == denied)
    }

    @Test func allowEditsTurnsADenialIntoACardAndNothingElse() {
        let policy = SideChatPolicy()
        policy.allowsEdits = true
        #expect(policy.decide(request("Write", ["file_path": "/tmp/a"])) == .ask)
        #expect(policy.decide(request("Edit", ["file_path": "/tmp/a"])) == .ask)
        #expect(policy.decide(request("Bash", ["command": "rm x"])) == .ask)
        // A read-only command stays answered without a card.
        #expect(policy.decide(request("Bash", ["command": "ls"])) == .allow)
        // And off again.
        policy.allowsEdits = false
        #expect(policy.decide(request("Write", ["file_path": "/tmp/a"])) == denied)
    }

    @Test func planModeIsDeniedAndOtherToolsAskAsInAMainSession() {
        let policy = SideChatPolicy()
        for allowing in [false, true] {
            policy.allowsEdits = allowing
            #expect(policy.decide(request("EnterPlanMode", [:])) == .deny(SideChatPolicy.planRefused))
            #expect(policy.decide(request("ExitPlanMode", [:])) == .deny(SideChatPolicy.planRefused))
            #expect(policy.decide(request("AskUserQuestion", ["questions": []])) == .ask)
            #expect(policy.decide(request("mcp__x__tool", [:])) == .ask)
            #expect(policy.decide(request("WebFetch", ["url": "https://example.com"])) == .ask)
        }
    }

    @Test func aSubagentsRequestGetsTheSameAnswer() {
        let policy = SideChatPolicy()
        #expect(policy.decide(request("Write", ["file_path": "/tmp/a"], agent: "agent-1")) == denied)
        #expect(policy.decide(request("Bash", ["command": "ls"], agent: "agent-1")) == .allow)
    }
}
