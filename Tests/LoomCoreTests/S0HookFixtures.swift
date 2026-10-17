import Foundation
@testable import LoomCore

/// Hook payloads as Claude Code 2.1.300 sent them in spike S0 (17 Oct 2026, recordings
/// `hooks-main`, `hooks-s2` .. `hooks-s5a`), trimmed to what the tests read and sanitized: ids, paths and
/// the working directory are made up, and long texts are cut. Field names, nesting and value shapes are
/// the recorded ones. A comment names the recording line each one follows.
enum S0Hooks {
    static let conversation = "0a0a0a0a-0000-4000-8000-000000000001"

    /// The keys every recorded payload carries (`transcript_path`, `cwd`, `scratchpad_dir`, `prompt_id`).
    static func payload(_ event: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "session_id": conversation, "hook_event_name": event, "cwd": "/tmp/ws",
            "transcript_path": "/tmp/cfg/projects/-tmp-ws/\(conversation).jsonl",
            "scratchpad_dir": "/tmp/scratch/\(conversation)/scratchpad", "prompt_id": "prompt-1",
        ]
        object.merge(fields) { _, new in new }
        return object
    }

    nonisolated(unsafe) static let sessionStart = payload("SessionStart", ["source": "startup", "model": "claude-haiku-5-5"])

    static func prompt(_ text: String) -> [String: Any] {
        payload("UserPromptSubmit", ["permission_mode": "default", "prompt": text])
    }

    // MARK: PermissionRequest (Q1)

    private nonisolated(unsafe) static let mode: [String: Any] = ["permission_mode": "default", "effort": ["level": "high"]]

    /// hooks-main L4.
    nonisolated(unsafe) static let writePermission = payload("PermissionRequest", mode.merging([
        "tool_name": "Write", "tool_input": ["file_path": "/tmp/ws/hello.txt", "content": "hello"],
        "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
    ]) { _, new in new })

    /// hooks-main L11.
    nonisolated(unsafe) static let editPermission = payload("PermissionRequest", mode.merging([
        "tool_name": "Edit",
        "tool_input": ["file_path": "/tmp/ws/hello.txt", "old_string": "hello", "new_string": "hello world", "replace_all": false],
        "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
    ]) { _, new in new })

    /// hooks-main L16: a compound command and the model's description.
    nonisolated(unsafe) static let bashPermission = payload("PermissionRequest", mode.merging([
        "tool_name": "Bash",
        "tool_input": ["command": "mkdir -p sub && touch sub/marker.txt", "description": "Create sub directory and empty marker.txt file"],
        "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "mkdir -p sub"]],
                                    "behavior": "allow", "destination": "localSettings"]],
    ]) { _, new in new })

    /// hooks-s4 L12: `questions[].header`.
    nonisolated(unsafe) static let askUserQuestion = payload("PermissionRequest", mode.merging([
        "permission_mode": "plan", "tool_name": "AskUserQuestion",
        "tool_input": ["questions": [[
            "question": "Which color do you prefer?", "header": "Color", "multiSelect": false,
            "options": [["label": "Red", "description": "Choose red"], ["label": "Blue", "description": "Choose blue"]],
        ]]],
    ]) { _, new in new })

    /// hooks-s4 L8: the plan text is in `tool_input.plan`.
    nonisolated(unsafe) static let exitPlanMode = payload("PermissionRequest", mode.merging([
        "permission_mode": "plan", "tool_name": "ExitPlanMode",
        "tool_input": ["plan": "# Plan: add a one-line README.md\n\n## Context\nThe working directory needs a README.md.",
                       "planFilePath": "/tmp/cfg/plans/plan.md"],
    ]) { _, new in new })

    /// hooks-s3 L17: a background subagent asks, after the main Stop (`agent_id`, `agent_type`).
    nonisolated(unsafe) static let subagentBashPermission = payload("PermissionRequest", mode.merging([
        "agent_id": "aff835c293c3ebaa6", "agent_type": "general-purpose", "tool_name": "Bash",
        "tool_input": ["command": "sleep 20", "description": "Sleep for 20 seconds"],
    ]) { _, new in new })

    // MARK: Notification (Q2)

    /// hooks-s2 L5, about 6 s after its PermissionRequest and only if the dialog was still open.
    nonisolated(unsafe) static let permissionPromptNotification = payload("Notification", [
        "message": "Claude needs your permission", "notification_type": "permission_prompt"])

    /// hooks-main L20, 60 s after the Stop.
    nonisolated(unsafe) static let idlePromptNotification = payload("Notification", [
        "message": "Claude is waiting for your input", "notification_type": "idle_prompt"])

    // MARK: Stop (Q3, Q4)

    /// hooks-main L18: the whole last message, here cut to two paragraphs.
    nonisolated(unsafe) static let stopDone = payload("Stop", mode.merging([
        "stop_hook_active": false,
        "last_assistant_message": "I ran `mkdir -p sub && touch sub/marker.txt` in the working directory. It finished with no output.\n\nThe folder exists now.",
        "background_tasks": [] as [Any], "session_crons": [] as [Any],
    ]) { _, new in new })

    /// hooks-s2 L13: a Stop while a background Bash still runs.
    nonisolated(unsafe) static let stopWithShell = payload("Stop", mode.merging([
        "stop_hook_active": false, "last_assistant_message": "started",
        "background_tasks": [["id": "beruee9od", "type": "shell", "status": "running",
                              "description": "Sleep 45 seconds in background", "command": "sleep 45"]],
        "session_crons": [] as [Any],
    ]) { _, new in new })

    /// hooks-s3 L6: a Stop while a background subagent still runs.
    nonisolated(unsafe) static let stopWithSubagent = payload("Stop", mode.merging([
        "stop_hook_active": false,
        "last_assistant_message": "The general-purpose agent is running in the background. I'll quote its answer when it reports back.",
        "background_tasks": [["id": "a39522eaa1d2d9921", "type": "subagent", "status": "running",
                              "description": "Answer 2+2 without tools", "agent_type": "general-purpose"]],
        "session_crons": [] as [Any],
    ]) { _, new in new })

    /// hooks-s2 L15: after the task ended, Claude starts a turn by itself.
    nonisolated(unsafe) static let taskNotificationPrompt = prompt(
        "<task-notification>\n<task-id>beruee9od</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n"
            + "<output-file>/tmp/tasks/beruee9od.output</output-file>\n<status>completed</status>\n"
            + "<summary>Background command \"Sleep 45 seconds in background\" completed (exit code 0)</summary>\n</task-notification>")

    /// hooks-s2 L16: the automatic turn ends, nothing left.
    nonisolated(unsafe) static let stopAfterTask = payload("Stop", mode.merging([
        "stop_hook_active": false, "last_assistant_message": "The background `sleep 45` finished with exit code 0.",
        "background_tasks": [] as [Any], "session_crons": [] as [Any],
    ]) { _, new in new })

    // MARK: SubagentStop with no start (Q5)

    /// hooks-s2 L14: about 1.8 s after a Stop, the prompt-suggestion agent: empty `agent_type`, a
    /// transcript path that does not exist, and a suggested next prompt as its "last message".
    nonisolated(unsafe) static let promptSuggestionStop = payload("SubagentStop", mode.merging([
        "agent_id": "a0bb3d137f01072df", "agent_type": "", "stop_hook_active": false,
        "agent_transcript_path": "/tmp/cfg/projects/-tmp-ws/\(conversation)/subagents/agent-a0bb3d137f01072df.jsonl",
        "last_assistant_message": "check whether the background sleep finished",
        "background_tasks": [] as [Any], "session_crons": [] as [Any],
    ]) { _, new in new })

    // MARK: StopFailure (Q6)

    /// hooks-s5a L3: `error` is a category; the human text is `last_assistant_message`; no `details`.
    nonisolated(unsafe) static let stopFailure = payload("StopFailure", [
        "effort": ["level": "high"], "error": "model_not_found",
        "last_assistant_message": "There's an issue with the selected model (claude-nonexistent-9). It may not exist or you may not have access to it.",
    ])

    // MARK: Wire

    static func envelope(_ fields: [String: Any], session: UUID, run: UUID, sentAt: Date) throws -> ClaudeHookEnvelope {
        ClaudeHookEnvelope(
            sessionID: session, managedRunID: run,
            payload: try JSONSerialization.data(withJSONObject: fields), sentAt: sentAt)
    }
}
