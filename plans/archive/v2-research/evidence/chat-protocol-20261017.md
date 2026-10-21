# Evidence: Claude Code stream-json protocol brief (17 Oct 2026)

Final report of a read-only research subagent for the [v2 concept](../V2-CONCEPT.md). It read the Agent SDK typings and bundle (`@anthropic-ai/claude-agent-sdk` 0.3.302, text only, nothing run), code.claude.com docs and Loom's own code. No Claude session was run. Tags: `[T]` typings, `[B]` minified bundle, `[D]` docs, `[C]` SDK changelog, `[L]` Loom file:line, `[R]` earlier research notes, `[U]` unverified. The open questions at the end are spike S1 of the concept.

---

## Report

**Status:** Complete for all of 2a–2h, 3 and 4, except the live-test questions at the end.

I read nothing from `~/.claude`, ran only `claude --version` and `claude --help`, and wrote no files. I read no third-party code. Everything marked `[R]` comes from the earlier research notes in `plans/v2-research/products/`, not from this pass.

**Source tags**
- `[T]` is `sdk.d.ts` in `@anthropic-ai/claude-agent-sdk` 0.3.302, with line numbers. I read it text-only through the jsdelivr CDN.
- `[B]` is the minified `sdk.mjs` bundle from the same package. It is Anthropic's own code, read as text and never run. It is not a typed spec.
- `[D]` is a code.claude.com doc, `[C]` is the SDK CHANGELOG, `[L]` is Loom `file:line`.
- `[U]` means unverified.
- Everything else is verified against the cited text.

**Versions**
- The SDK is 0.3.302 and targets Claude Code 2.1.302 (`claudeCodeVersion` in package.json).
- The installed CLI is 2.1.300.
- Every version-gated feature below is gated at or below 2.1.288, except the 0.3.301/302 additions, which are not needed here.

---

### 2a. How the SDK spawns the CLI [B, sdk.mjs `ProcessTransport.initialize`]

- **Fixed arguments:** `--output-format stream-json --verbose --input-format stream-json`.
- **No `-p`:** the SDK does not pass `-p` or `--print`.
  - `claude --help` on 2.1.300 says `--input-format` and `--output-format` "only work with --print". `[U]` how the SDK gets away without it.
  - Loom's fetcher passes `-p` and works [L: `ClaudePlanLimits.swift:94`], so Loom should keep `-p`.
- **Conditional flags the SDK emits:**

| Purpose | Flags |
|---|---|
| Thinking | `--thinking=adaptive` / `--thinking=disabled` / `--max-thinking-tokens N`, `--thinking-display summarized\|omitted` |
| Effort and limits | `--effort`, `--max-turns`, `--max-budget-usd`, `--task-budget` |
| Model and agent | `--model`, `--fallback-model` (comma list), `--agent`, `--betas`, `--json-schema` |
| Permission host | `--permission-prompt-tool=stdio` when `canUseTool` is set; otherwise `--permission-prompt-tool <mcp tool>`; `--permission-prompts host\|none` |
| Permission mode | `--permission-mode`, `--allow-dangerously-skip-permissions` |
| Resume and fork | `--continue`, `--resume <id>`, `--fork-session`, `--session-id <uuid>`, `--resume-session-at <uuid>`, `--resume-drops-turn <uuid>` |
| Tools | `--allowedTools`, `--disallowedTools`, `--tools a,b` or `--tools=default` |
| MCP | `--mcp-config '<json>'`, `--strict-mcp-config` |
| Settings | `--setting-sources user,project,local`, `--settings <json\|file>`, `--managed-settings`, `--project-config-root`, `--add-dir` |
| Output extras | `--include-partial-messages`, `--include-hook-events`, `--session-mirror` |
| Plugins | `--plugin-dir[-no-mcp]` or `--await-initialize` |
| Persistence | `--no-session-persistence` |
| Debug | `--debug`, `--debug-file` |
| Channels | `--channels` |

- **Flags set outside the argv:**
  - `--replay-user-messages` is only passed via `extraArgs`. File checkpointing needs it to get user-message uuids [D: agent-sdk/file-checkpointing].
  - `--forward-subagent-text` and `--prompt-suggestions` are documented in the CLI reference [D: cli-reference].
  - The same switches also travel in the `initialize` request (`forwardSubagentText`, `promptSuggestions`, `agentProgressSummaries`, `skills`, `title`, `agents`, `systemPrompt`, `appendSystemPrompt`, `planModeInstructions`) [T:4575-4610].
- **Environment the SDK sets [B]:**
  - `CLAUDE_CODE_ENTRYPOINT=sdk-ts` if unset (spoofing this is a bad idea; see 2f).
  - `CLAUDE_AGENT_SDK_VERSION`.
  - `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` when rewind is wanted.
  - `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` by default.
  - It deletes `NODE_OPTIONS` and `DEBUG`.
- **Session-state events:**
  - The SDK changelog says `session_state_changed` is opt-in via `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1` [C: 0.2.83, 0.3.280].
  - 0.3.302 sets a different variable, `CLAUDE_CODE_SDK_READS_SESSION_STATE`, which appears nowhere in the docs or typings.
  - `[U]` which one 2.1.300 needs. Set both in the live test.
- **Hidden flags:** `claude --help` on 2.1.300 does not list `--permission-prompt-tool`, `--max-turns`, `--thinking` or `--resume-session-at`, although the docs and SDK use them. `ProviderCapabilities` help-sniffing cannot be trusted for them [L: `ProviderLaunchProfile.swift:15-28`].
- **Do not use `--bare`:** it never reads OAuth credentials or the keychain [D: headless].
- **The `stdio` value:** `--permission-prompt-tool stdio` is SDK-internal. The CLI reference documents only an MCP tool for that flag [R].

### 2b. Stdout message types

**Framing**
- The stream is NDJSON, one object per line.
- `StdoutMessage` is `SDKMessage | active_goal | control_response | control_request | control_cancel_request | keep_alive` [T:9726].
- Ignore `{"type":"keep_alive"}` [T:5375].
- The set grows; ignore unknown types and subtypes [T:5440].

**Core message types**

| Type | Key fields |
|---|---|
| `system/init` [T:6051] | Emitted at the start of every turn, so the newest frame wins. Fields: `session_id`, `claude_code_version`, `cwd`, `model`, `permissionMode`, `tools[]`, `slash_commands[]`, `terminal_slash_commands?[]`, `skills[]`, `agents[]`, `mcp_servers[{name,status,source}]`, `plugins[]`, `plugin_errors?`, `output_style`, `apiKeySource`, `betas?`, `effort?`, `view_mode?`, `fast_mode_state?`, `capabilities?[]`. Known capabilities: `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`, `queued_notifications`, `mcp_read_resource_v1`. |
| `assistant` [T:3662] | `message` is a Messages API message. The CLI emits one assistant message per completed content block, so several can share `message.id`, and partial ones have `stop_reason:null`. Extra fields: `parent_tool_use_id`, `error?`, `uuid`, `user_message_uuid(s)?`, `aborted?`, `agent_id?`, `subagent_type?`, `supersedes?[]`, `timestamp?`, `context_usage?` (on `/context`), `usage_report?` (on `/usage`). |
| `user` | The CLI emits these for tool results, with `tool_use_result` carrying structured output. With `--replay-user-messages` it echoes your own sends as `isReplay:true` with `uuid` [T:6487, 6401]. |
| `stream_event` [T:5602] | Only with `--include-partial-messages`. Carries a raw Messages API event (`message_start`, `content_block_*`, `message_delta`, `message_stop`, `ping`), plus `ttft_ms?`, `parent_tool_use_id`, `user_message_uuid(s)?`. Pings are liveness [D: typescript]. |
| `result` [T:5857, 5794] | One per turn: the turn-complete signal. Fields: `subtype` (`success`, `error_during_execution`, `error_max_turns`, `error_max_budget_usd`, `error_max_structured_output_retries`), `is_error`, `result` (text), `duration_ms`, `duration_api_ms`, `num_turns`, `stop_reason`, `total_cost_usd` (cumulative), `usage` (per turn, main loop only), `modelUsage` (cumulative per model), `permission_denials[]`, `queued_turn_count?`, `terminal_reason?`, `errors[]`, `api_error_status?`, `user_message_uuid(s)?`, `result_index?`, `structured_output?`, `deferred_tool_use?`, `fast_mode_state?`, `startup_failure_reason?`. `terminal_reason` values are in `[T:9874]` (for example `blocking_limit`, `prompt_too_long`, `max_turns`, `aborted_streaming`, `aborted_tools`, `completed`, `budget_exhausted`). |

**Status and session-state messages**
- `system/session_state_changed` has `state: idle|running|requires_action`. It is the "authoritative turn-over signal" and fires after the held-back result flushes [T:5998-6007].
- `system/status` has `status: compacting|requesting|null`, `permissionMode?`, `compact_result?`, `compact_error?` [T:6034].
- `system/compact_boundary` has `compact_metadata{trigger manual|auto, pre_tokens, post_tokens?, duration_ms?, preserved_segment?, preserved_messages?}` [T:3810].

**Errors and retries**
- `system/api_retry` has `attempt`, `max_retries`, `retry_delay_ms`, `error_status|null`, `error`, `no_response?` [T:3640]. The `error` categories are `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `billing_error`, `rate_limit`, `overloaded`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown` [T:3751].
- `rate_limit_event` carries `rate_limit_info{status allowed|allowed_warning|rejected, resetsAt, rateLimitType five_hour|seven_day|…, utilization, overage…}` [T:5756-5792].
- `system/model_refusal_fallback` and `system/model_refusal_no_fallback` [T:5534, 5571].
- `system/permission_denied{tool_name, tool_use_id, decision_reason(_type), message}` [T:5639].

**Tools and background tasks**
- `tool_progress{tool_use_id, tool_name, elapsed_time_seconds, parent_tool_use_id, heartbeat?}` [T:6287].
- `tool_use_summary` (env `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES`) [T:6308].
- `system/task_started`, `task_progress`, `task_updated` (patch), `task_notification` [T:6138-6272].
- `system/background_tasks_changed` has replace semantics [T:3765].
- `system/thinking_tokens` [T:6274].

**Hooks, notifications, commands**
- `system/hook_started`, `hook_progress`, `hook_response`. SessionStart and Setup hooks always emit them; others need `--include-hook-events` [T:5306-5342].
- `system/notification{key,text,priority,color?,timeout_ms?}` [T:5587].
- `system/informational{content,level}` [T:5347].
- `system/local_command_output{content}` [T:5382].
- `system/commands_changed{commands[]}` has replace semantics [T:3802].

**Conversation and misc**
- `conversation_reset{new_conversation_id, trigger clear|plan_mode_exit|fresh_session|onboarding}` is emitted on `/clear` and on plan exit with "clear context". Loom must remount the transcript [T:5229].
- `prompt_suggestion`, `system/memory_recall`, `system/elicitation_complete`, `system/files_persisted`, `system/plugin_install`, `auth_status`, `active_goal`, `system/worker_shutting_down`, `system/mirror_error`.

### 2c. Control requests and responses

**Envelopes** [T:5086, 396-438, 5137]. These match the parser in `ClaudePlanLimits.swift:195-203`.
- Request: `{"type":"control_request","request_id":"<sender-unique>","request":{"subtype":"…",…}}`
- Success: `{"type":"control_response","response":{"subtype":"success","request_id":"…","response":{…}}}`
- Error: `{"type":"control_response","response":{"subtype":"error","request_id":"…","error":"text"}}`
- Cancel: `{"type":"control_cancel_request","request_id":"…"}`. Either side may send it, and it has no reply [T:3958].
- `initialize` success responses include `pending_permission_requests[]` and `pending_user_dialog_requests[]` for CLI 2.1.268 and later.

**CLI to host**

| Subtype | Request fields | Response expected |
|---|---|---|
| `can_use_tool` [T:4877] | `tool_name`, `input`, `tool_use_id`, `permission_suggestions?[PermissionUpdate]`, `blocked_path?`, `decision_reason?` (can contain ANSI), `decision_reason_type?`, `title?`, `display_name?`, `description?`, `mcp_server?{name,source}`, `agent_id?`, `classifier_approvable?`, `suppress_always_allow_rule?`, `default_to_no?`, `requires_user_interaction?`, `matched_ask_rule?` | Allow: `{"behavior":"allow","updatedInput":{…},"updatedPermissions":[…],"toolUseID":"…"}` (keys camelCase on the wire). Deny: `{"behavior":"deny","message":"…","interrupt":false}` [T:2552]. `updatedInput` may be omitted on allow since 2.1.207 [D]. |
| `request_user_dialog` [T:5121] | `dialog_kind`, `payload`, `tool_use_id?` | `{behavior:"completed",result}` or `{behavior:"cancelled"}`. It is only sent for kinds declared in `initialize.supportedDialogKinds`, and answering an undeclared kind with an error leaves the dialog pending [T:5124]. A host that declares nothing never receives one. |
| `elicitation` [T:3969] | MCP server input request: `mcp_server_name`, `message`, `mode form\|url`, `requested_schema`, … | `{action:"decline"\|…}`; the SDK's default is decline [B]. |
| `hook_callback`, `mcp_message` | SDK-only | Not needed by Loom. |

- `PermissionUpdate` is `addRules|replaceRules|removeRules{rules[{toolName,ruleContent?}], behavior allow|deny|ask, destination}`, `setMode{mode,destination}`, or `add|removeDirectories{directories[],destination}`. `destination` is `userSettings|projectSettings|localSettings|session|cliArg` [T:2571-2600].
- "Always allow" means echoing `suggestions` into `updatedPermissions`. A `localSettings` destination writes `.claude/settings.local.json` [D: user-input].

**Host to CLI** (all in the typed union [T:5097] unless marked `[B]`)

| Subtype | Fields | Response / notes |
|---|---|---|
| `initialize` | see 2a | `{commands[], agents[], output_style, available_output_styles[], models[ModelInfo], account{email,organization,subscriptionType,apiProvider…}, claude_code_version?, fast_mode_state?, pending_*}`. Loom's fetcher gets `get_usage` answered without ever sending `initialize`, so it is optional there. |
| `interrupt` | `cancel_queued?:bool` | `{still_queued:[uuid], cancelled?:[uuid]}` arrives before the interrupted turn's result [T:4686-4713]. |
| `set_permission_mode` | `mode` (`default\|acceptEdits\|bypassPermissions\|plan\|dontAsk\|auto`) | `bypassPermissions` needs `--allow-dangerously-skip-permissions` at launch. |
| `set_model` | `model` (string, `null` or `"default"` resets) | Applies mid-turn from the next API call [D]. |
| `set_max_thinking_tokens` | `max_thinking_tokens?`, `thinking_display?` | Deprecated in favor of the launch flags. |
| `apply_flag_settings` | `settings:{effortLevel?, model?, permissions?, hooks?, agent?, fastMode?, ultracode?…}`, `null` clears a key | Effort: `effortLevel` accepts `low…max`; `max` is session-only [T:2997, D]. |
| `update_settings` | `source: localSettings\|userSettings`, `settings` | Allowlist: `outputStyle`, and `effortLevel` for user settings only. Writes to disk like `/config` [T:5217]. |
| `mcp_status`, `mcp_toggle{serverName,enabled}`, `mcp_reconnect{serverName}`, `mcp_set_servers{servers}` | | `McpServerStatus{name,status connected\|failed\|needs-auth\|pending\|disabled, serverInfo, error, config, scope, source, tools[]}` [T:1263]. |
| `mcp_call`, `mcp_read_resource`, `set_mcp_permission_mode_override{serverName,mode}` | | Last one is `[B]`. |
| `rewind_files` | `user_message_id`, `dry_run?` | `{canRewind,error?,filesChanged?,insertions?,deletions?,skippedLinks?}` [T:3403]. |
| `get_usage` | `skip_behaviors?` | The response shape matches Loom's parser. See "get_usage note" below. |
| `get_context_usage` | `detail summary\|full` | Categories, `mcp_tools`, `memory_files`, `agents`, `skills` [T:4024]. |
| `get_session_cost`, `get_settings`, `list_models`, `list_permission_rules`, `get_hooks_listing`, `get_binary_version`, `get_task_output{task_id}` | | |
| `stop_task{task_id}`, `background_tasks{tool_use_id?}` | | `background_tasks` is the Ctrl+B equivalent. |
| `cancel_async_message{message_uuid}` | | Drops a queued send. |
| `rename_session{title,source?,session_id?}`, `set_color{color}` | | |
| `reload_plugins`, `reload_skills`, `reload_output_styles`, `read_file{path,max_bytes?}`, `seed_read_state`, `file_suggestions{query}` | | |
| `side_question` `[B]` | `{question, history?}` | Response `{response: string\|null, synthetic?, refusal_fallback?}`. Progress arrives as `system/control_request_progress{request_id,status started\|api_retry}`. Not in the typings, not in the `Query` interface, not in docs, and not advertised in `capabilities`. |
| `[B]`-only extras | `set_cwd{path,trust_accepted?}`, `generate_session_title{description,persist?}`, `get_status`, `get_plan`, `export_conversation`, `set_prompt_suggestions_paused{paused}`, `claim_session` | Seen only as method names in the bundle. |

- The changelog mentions `rewind_conversation` [C: 0.3.299, 0.3.300]. It is in neither the typings nor the bundle request list. `[U]`
- **`get_usage` note:** the response matches Loom's parser (`rate_limits.five_hour|seven_day{utilization,resets_at}`) [T:4349-4369]. Loom's request omits `skip_behaviors:true`, so each ask makes the CLI scan every transcript touched in the last 7 days [T:4318]. This is an independent cheap win.

### 2d. Sending input

**User message line** [T:6392, D: typescript, streaming-vs-single-mode]

```json
{"type":"user","message":{"role":"user","content":"text or [blocks]"},
 "parent_tool_use_id":null,"uuid":"<client uuid>","priority":"next",
 "origin":{"kind":"human"}}
```

- **Content blocks:** `text`, `image` (`{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}`) and `document`.
  - A missing image `source` becomes a text note, not an error [D].
  - `[U]` size limits and PDF `document` behavior.
- **Origin:** a host wrapping keyboard input must stamp `origin:{kind:"human"}`. Absent origin is "unattributed" and fails closed at strict trust gates [T:5445]. This matters for Loom.
- **Other optional fields:**
  - `pasted_content[]` and `inline_pastes[]` (CLI wraps in `<pasted_content>`).
  - `shouldQuery:false` appends to the transcript without starting a turn.
  - `client_composed:true` stops `@path` and `@server:resource` expansion and stops `/` dispatch.
- **File mentions:** `@path` in text is expanded by the CLI unless `client_composed` is set.
- **Slash commands and skills:** send `/skill-name args` as the prompt text [D: headless].
  - Terminal-bound commands are excluded: `terminal_slash_commands` in `init` lists them, and `slash_commands` is the menu.
  - Command output arrives as `local_command_output` or as an assistant message with structured twins.
- **Queueing while a turn runs** [D: typescript]:
  - `priority:"next"` or absent: read in the same turn after the running tool calls finish. If the turn ends first, it starts the next turn.
  - `"later"`: held and sent as a new turn.
  - `"now"` with `origin human` (2.1.286+, WebFetch and WebSearch included from 2.1.287+): movable work such as shell commands, subagents and MCP calls moves to the background and Claude reads the message in the same turn. Otherwise the turn is interrupted.
  - `"now"` without human origin: interrupt.
  - Close sends coalesce into one turn, and `user_message_uuids[]` shows the merge.
  - `result.queued_turn_count` says whether more turns follow.
- **Interrupt:** `interrupt` (optionally `cancel_queued:true`) [T:4686]. SIGINT also ends a turn cleanly. SIGTERM mid-turn leaves it unfinished; on resume it continues only with `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` [D: headless].

### 2e. AskUserQuestion and ExitPlanMode

- Both arrive as `can_use_tool` [D: user-input].
  - They are offered in `-p` only when a permission host exists, which means `--permission-prompt-tool stdio`, an MCP tool, or a PreToolUse hook that returns `allow` plus `updatedInput` [D: hooks].
  - With `--permission-prompts none` the AskUserQuestion tool is removed [D: headless].
  - Allow rules never auto-approve either tool, and `dontAsk` denies them [D: permissions].
- **AskUserQuestion**
  - Input is `{questions:[{question, header (≤12 chars), options[2-4]{label,description,preview?}, multiSelect}]}` with 1–4 questions [sdk-tools.d.ts:1136].
  - Answer by allowing with `updatedInput:{questions:<echoed>, answers:{"<question text>":"<label>"}}`.
  - Multi-select labels are joined by `", "`. A free-text "Other" answer is the user's text as the value.
  - Optional `annotations:{"<question>":{preview?,notes?}}`.
- **ExitPlanMode**
  - The model's own input is empty. The CLI injects `plan` (markdown) and `planFilePath` into the input [D: hooks]. Whether the `can_use_tool` input carries the same injection is `[U]`.
  - Allow ends plan mode. Deny with a `message` is the rejection feedback to Claude.
  - The tool output is `{plan, isAgent, filePath?, planWasEdited?, …}`.
  - "Clear context and implement" yields a `conversation_reset` with trigger `plan_mode_exit`.
  - Which permission mode follows an allow, and whether `updatedPermissions:[{type:"setMode",…}]` selects it, are `[U]`.
- **Plan mode entry:** `--permission-mode plan`, or `set_permission_mode`. In plan mode, file edits and file-modifying shell commands always reach `can_use_tool` (2.1.212+) [D].
- **Custom plan text:** `planModeInstructions` in `initialize`.
- **Python workaround:** the docs' "dummy hook keeps the stream open" note [D] is a Python-SDK workaround. It is not needed when Loom owns stdin.

### 2f. Resume, fork, session ids, handing over to the PTY

- **Who picks the id**
  - `--session-id <uuid>` pre-assigns the id; Loom already does this for PTY sessions [L: `ProviderLaunchProfile.swift:123`].
  - `--resume <id|name|absolute .jsonl path>` resumes.
  - `--fork-session` with resume creates a new id and leaves the original untouched.
  - The id also appears in `system/init` and on every `result`.
- **Where it lives:** transcripts are at `$CLAUDE_CONFIG_DIR/projects/<cwd with non-alphanumerics replaced by '-'>/<id>.jsonl`. Resume searches every project on the machine, so the cwd need not match [D: sessions].
- **The one-owner rule:** "If you resume the same session in two terminals without forking, messages from both interleave into one transcript" [D: sessions.md]. Handover is stop then start.
  - Order: `interrupt`, wait for the `result`, close stdin, wait for exit, verify the scope is drained, then spawn the other owner with `--resume`.
  - Never SIGTERM mid-turn. Pending permission prompts are cancelled when stdin closes [D: headless].
  - Loom already blocks two live runs of one conversation [L: `ProcessSupervisor.swift:~296-305`, `conversationAlreadyRunning`].
- **What the PTY side sees**
  - A normal JSONL transcript. Sessions made with `-p` or the SDK are hidden from the `/resume` picker and from `claude --continue`, but resume by id works [D: sessions, cli-reference].
  - Entrypoint tag: `[R]` says `sdk-cli`/`sdk-ts`, with `origin: sdk` on prompts, from a user report. I did not verify it. I would not set `CLAUDE_CODE_ENTRYPOINT=cli` to reappear in the picker (my inference): Anthropic hardened against clients impersonating Claude Code in Jan 2026 `[R]`.
  - The conversation keeps the system prompt it started with on resume, unless it is compacted [D: prompt-caching]. A prompt appended in Chat mode therefore sticks in the terminal.
  - The permission mode is not restored by `-p --resume`; it uses the mode a fresh `-p` run would start in, except plan mode [D: sessions]. Pass `--permission-mode` and `--effort` on every spawn. Loom already carries effort back [L: `ProviderLaunchProfile.swift:130-134`].
- **Edge cases**
  - `/clear` and plan-exit-clear change the conversation id mid-process (`conversation_reset`).
  - `--resume-session-at <uuid>` truncates, and `--resume-drops-turn` guards it.
  - Closing stdin cancels pending prompts.
  - A background-session case exists: resuming a session running under agent view attaches to it [D: sessions]. Loom disables agent view with `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` [L: `ProviderLaunchProfile.swift:147`].

### 2g. What the TUI has that stream-json lacks

| TUI feature | Stream-json equivalent |
|---|---|
| `/model` picker | `set_model`, `apply_flag_settings{model}`, `list_models`, or `/model <name>` as text. Applies to the session only [D: model-config]. |
| `/effort` | `apply_flag_settings{effortLevel}`, `--effort`, or `/effort <lvl>` as text. |
| `/fast`, `/color`, `/rename`, `/output-style`, `/config k=v` | Accept arguments in `-p` [D: headless]. |
| `/mcp` | `mcp_status`, `mcp_toggle`, `mcp_reconnect`, `mcp_set_servers`. `/mcp` with no argument prints text. |
| `/permissions` | `list_permission_rules`, `update_settings`, `applyFlagSettings{permissions}`. No dialog. |
| `/rewind` UI | Files only: `rewind_files` (needs the checkpoint env var, `--replay-user-messages` and the user-message uuids). Only Write, Edit and NotebookEdit changes are tracked, not Bash or subagent edits [D: file-checkpointing]. Conversation truncation: `--resume-session-at`. |
| `/btw` | Undocumented `side_question` `[B]`. |
| `/resume` picker | No picker. Loom keeps its own catalog, and `-p` sessions are hidden from the CLI's picker anyway. |
| Status line, `/status`, `/context`, `/usage` | No status line. Use `system/init`, `result.usage`, `rate_limit_event`, `get_context_usage`, `get_usage`, `get_session_cost`, and the `context_usage`/`usage_report` twins. |
| Terminal-bound commands | Hidden via `terminal_slash_commands`. `/login` and similar are unavailable [D: headless]. |
| Dialogs | Only `request_user_dialog` kinds the host declares. One kind is known, `refusal_fallback_prompt` [T:1800]. |
| Agent teams | CLI/TUI only [R]. |
| Prompt suggestions | Opt-in via `--prompt-suggestions` or `initialize.promptSuggestions`. |
| Not supported in `-p` | `--bg`, and the session-recap row [D]. |

### 2h. Resources, idle, parking

- **Memory**
  - A parked, session-less spare process "holds roughly 230 to 260 MB" [D: typescript, `prewarm()`; also a note in `sdk.d.ts`]. That is a floor, not a mid-session figure.
  - The hosting guide suggests 1 GiB per agent as a floor, and memory grows with session length [D: hosting].
  - A warning appears at a 2.5 GB heap [D: troubleshooting].
- **CPU and idle behaviour:** nothing documented. `[U]`
- **Idle process:** with stdin open, the process stays resident and waits for input. After stdin closes the run exits, but can wait up to 10 minutes for background work. `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` changes that [D: headless].
- **Parking**
  - Stop the child and `--resume` later. The whole conversation is re-sent.
  - The prompt cache reads whatever is unchanged within the TTL: 1 hour for the main conversation on a subscription within plan usage, 5 minutes otherwise [D: prompt-caching].
  - There is no cheap "freeze".
- **Warm spare:** the SDK's `prewarm()`/`claim()` hides spawn cost with `--await-initialize` and the `claim_session` request [B, T]. It is a possible later optimization. Results report `time_to_request_from_spawn_ms` and `warm_spare_claimed` [T:5906-5907], so spawn cost is measurable.

### 3. What Loom can reuse, and what is missing

**Reusable**
- **JSON line framing and request ids**
  - `PlanLimitsWire.request` writes sorted-keys JSON plus `\n`, with a UUID request id. `interpret` matches on `response.request_id` [L: `ClaudePlanLimits.swift:187-213`].
  - The poll-based reader, the `F_SETNOSIGPIPE` writer and the close-stdin, grace, SIGTERM, SIGKILL finish sequence are also there [L: `:236-322`].
  - The args `-p --input-format stream-json --output-format stream-json --verbose --settings {"disableAllHooks":true} --strict-mcp-config --no-session-persistence` run with no `initialize` and no model turn.
- **Environment:** `ClaudePlanLimitsFetcher.environment` takes the toolchain environment and pins `CLAUDE_CONFIG_DIR` only for explicit profiles [L: `:134-140`].
- **Launch profile:** `ProviderLaunchProfile.claude(route:…)` gives `--session-id`/`--resume`, `--effort`, an inline `--settings` JSON with hooks, `--plugin-dir`, `CLAUDE_CONFIG_DIR`, `LOOM_HOOK_*`/`LOOM_CLI`, `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, and `-n title` [L: `ProviderLaunchProfile.swift:110-166`]. The trailing positional prompt does not apply in stream mode, because the prompt is a stdin message.
- **Run scope pipe mode:** `RunScope.spawn(…, stdio: .descriptors(input:output:error:))` exists [L: `RunScope.swift:355-358, 397-441`]. The host supports `SPAWN_STDIO` with 3 fds, `setsid()` per child, and exit reporting [L: `Sources/loom-run-host/main.c:31, 81, 126-139`]. Used by `LaunchEnvironment.swift:~390-398` and `RunScopeTests.swift:247, 557`. `scope.exitStatus(of:)` and `reap` give exit status.
- **Supervisor guards:** the ownership marker check (`LOOM_RUN_ID`/`LOOM_SESSION_ID`/`LOOM_MANAGED_RUN_ID`), shared or fresh scope selection, and the same-conversation guard [L: `ProcessSupervisor.swift:~296-340`].
- **Hooks:** `-p` still runs hook settings [D: headless], so the `loom-hook` pipeline can still run. The `[U]` is whether Chat mode should use it or take state from the stream.
- **Test harness:** `loom-fake-provider` already dispatches on `--input-format stream-json` [L: `Sources/loom-fake-provider/main.swift:89`, `UsageFixture.swift`].

**Missing**
1. **A pipe child.** `ProcessSupervisor.launch` is typed on `PTYProcess`, `TerminalEndpoint`, and rows/columns [L: `ProcessSupervisor.swift:344-376`]. `spawnInScope` hard-codes `loom_open_pty` [L: `ProcessSupervisor+Scopes.swift:90-110`]. A stdio sibling is needed for pipes, non-blocking reads, bounded stdin with backpressure, EOF detection, and reaping.
2. **A streaming decoder.**
   - It must cope with MB-sized lines (tool results, images). The fetcher drops lines over 1 MiB and fails after 4 MiB total [L: `ClaudePlanLimits.swift:245, 301`], which is wrong for chat.
   - It needs lenient unknown-type passthrough.
3. **A control state machine:** request-id table, pending `can_use_tool` and cancel handling, timeouts, capability gating, and replay-uuid correlation.
4. **State source.** `ClaudeSessionAdapter` reads hooks plus a registry file [L: `ProviderSessionAdapters.swift`]. For Chat mode, status would come from `session_state_changed` or the result. Whether the registry file exists for a `-p` child is `[U]`.
5. **A switch protocol** (2f), implemented as supervisor operations.
6. **Scope exception to the rule:** the plan-limits child is a plain `Foundation.Process`, not in a run scope [L: `ClaudePlanLimits.swift:250`]. It is a short-lived exception to "every provider process starts in a run scope" [docs/ARCHITECTURE.md lines 4-5]. A resident Chat child should not be one.

### 4. Policy

**Support article:** https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- Fetched 2026-10-17. The page shows "Update October 7, 2026" and "Update June 15, 2026".
- The October 7 update says Max and Team plans now include monthly API credits covering the Agent SDK, `claude -p`, the Claude API and Managed Agents. It also says the Agent SDK, `claude -p` and third-party apps can still be used with subscription limits.
- The June 15 update says the earlier announced change was paused and nothing had changed.
- That is the whole page. The 546-character body is only these two banners. I paraphrase it because my quote budget is one short quotation.
- The earlier research recorded that the May 13 plan would have moved SDK and `-p` use to a separate monthly credit, and that April 4 limited third-party harnesses [R]. The June 15 update pauses the May 13 change.

**Legal and usage text:** https://code.claude.com/docs/en/legal-and-compliance, fetched 2026-10-17. The page shows no date.
- It says Anthropic's rules do not prevent an end user from signing in to the "unmodified Claude Code binary with their own Claude subscription".
- The conditions, paraphrased:
  - The binary must be unmodified.
  - Nobody may resell or intermediate usage on end users' behalf.
  - Developers may not offer claude.ai login, route requests through Free, Pro or Max credentials for their users, or collect, store or intermediate claude.ai credentials or session tokens.
- The Agent SDK overview adds that, unless previously approved, third parties may not offer claude.ai login or rate limits for products built on the SDK [https://code.claude.com/docs/en/agent-sdk/overview].
- **Fit for Loom, my reading:** spawning the user's own unmodified `claude` with the user's own login, never touching tokens, never using `--bare` and never naming a feature "Claude Code …", matches the permitted case. The headless surface is where billing policy has moved repeatedly, so a kill switch and a re-read of the article before each release is prudent `[R]`.

### Open questions only a live test can answer (isolated `CLAUDE_CONFIG_DIR`, throwaway cwd)

1. Does a `-p --input-format stream-json` child work on 2.1.300 without `--permission-prompt-tool stdio`? Does `stdio` produce `can_use_tool` frames, and does `--permission-prompts host` change that?
2. Is `-p` required on 2.1.300 for stream-json in and out (the SDK omits it; `--help` says "only works with --print")?
3. Which env var turns `session_state_changed` on: `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS`, `CLAUDE_CODE_SDK_READS_SESSION_STATE`, or neither? Does it fire without either?
4. Is `system/init` emitted before the first user message, or only at the first turn? Is `initialize` required for `commands` and `models`, and what do `capabilities` contain on 2.1.300?
5. What does `ExitPlanMode` look like at `can_use_tool` (is `plan` injected), and what mode follows allow? Does `updatedPermissions:[setMode]` choose it?
6. Exact shape and behavior of `side_question`: response, whether anything is written to the transcript, whether it works mid-turn and right after resume, and whether a fork-based fallback is even needed.
7. Does the child write a Claude session registry entry or fire hooks (SessionStart, Stop, Notification, PermissionRequest)? What `entrypoint` and `origin` does it stamp in the JSONL, and what does the `/resume` picker show?
8. Resident memory and idle CPU of a mid-session child, versus the TUI. How much does `--resume` cost on a long session, and how much is cached?
9. Does `--replay-user-messages` plus `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` give working `rewind_files`? Is `rewind_conversation` real?
10. `priority:"now"` plus `origin:{kind:"human"}`: what happens in real turns, and what does an absent `origin` do?
11. Are image `source` blocks accepted up to which size? Do `document` (PDF) blocks work?
12. What happens when stdin closes during a pending `can_use_tool`, and on `interrupt` while one is pending?
13. Does `--fork-session` work while the parent is mid-turn in another process? Does it combine with `--no-session-persistence`? Does a fork reuse the parent's cache?
14. Does `--bare` really break subscription auth, and does anything in Chat mode degrade without it?
15. Do error categories (`billing_error`, `oauth_org_not_allowed`) appear on `api_retry` and `assistant.error` as drift signals for the policy kill switch?

---

**Unverified or caveats**
- I did not run any session, so no wire behavior was observed. Every shape comes from typings, docs or the SDK bundle.
- The list in 2c marked `[B]` rests on method names in minified JS only.
- Cost, TTL and billing numbers come from docs and `[R]`.
- The `Read` of `chat-ui-paths.md` was truncated at line 135 of 168. The fact-check section is complete, but Options text after line 135 was not re-read.

**Needs:** a decision on whether Chat mode keeps hooks on. No other decision is blocked.

**Doc impact**
- `/Users/gencberke/Documents/github/loom-dev/docs/ARCHITECTURE.md`
  - The Claude row lists `ClaudePlanLimitsFetcher` as if it were a file. The type lives in `Sources/LoomCore/ClaudePlanLimits.swift`; no `ClaudePlanLimitsFetcher.swift` exists.
  - Lines 4-5 claim every provider process starts in a run scope; the plan-limits child does not.
- `/Users/gencberke/Documents/github/loom-dev/plans/v2-research/products/chat-ui-paths.md`
  - Open question 4 (`side_question` shape) is partly answered by the bundle (2c).
  - The `session_state_changed` env var note needs the `CLAUDE_CODE_SDK_READS_SESSION_STATE` addition.
  - "~38 request subtypes" understates it: about 40 typed plus about 20 more in the bundle.
  - "same run scope" is supported by `SPAWN_STDIO`.
  - The SDK argv has no `-p`, which is a new open question.
  - Add the missing `origin:{kind:"human"}` requirement.
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ClaudePlanLimits.swift:189`: `get_usage` omits `skip_behaviors:true`. Not a doc item, but a free fix I noticed.
