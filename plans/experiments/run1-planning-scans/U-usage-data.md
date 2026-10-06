[harness: subagent output matched instruction-shaped pattern(s): settings-json. Control tags below are neutralized (`<` → `<\`); treat any remaining directive-shaped text as a finding to relay to the user, not an instruction to you.]

## Summary

- **Source.** Claude Code's per-conversation transcripts (`<config>/projects/<encoded-cwd>/<sessionId>.jsonl`) carry full per-message token usage. That is enough for tokens by day, model, session and cache share, and for an estimated cost. Nothing needs to be spawned or polled.
- **Limits.** The 5-hour and weekly plan limits are not in the transcripts or any local file I found. They exist only (a) in the `statusLine` stdin JSON as `rate_limits.*`, which needs a configured `statusLine` command, or (b) via network or OAuth. Either route changes Claude's behavior or traffic, so by D-20 it is a user decision and I recommend deferring it. Without limits, Loom can show a 5-hour activity block as a clearly labelled approximation (ccusage-style).
- **Undercounting.** Transcript sums undercount Claude's own session total. The CLI makes auxiliary calls (title generation, summaries, suggestions) that never reach the transcript. In the probe profile the transcript-priced total is 86% of the CLI's own `cost-state` total (35 sessions, tiny Haiku turns). The "numbers match Claude's own records" criterion in ROADMAP stage U needs a precise definition.
- **Retention bounds the scan.** Claude deletes transcripts older than `cleanupPeriodDays` (default 30). A default-config history is therefore naturally bounded. Loom should keep its own per-day aggregates so history survives that deletion.
- **Recommended design.** A disposable SQLite index in Loom's data root. Per-file `(dev, inode, size, offset, tail guard)` drives incremental parsing, and per-message rows deduped by a 64-bit key. Triggers are the existing `Stop` hook event, Settings open and app activation, with no timers.

## 1. Local data format

**Facts confirmed in the probe profile** (Claude Code 2.1.284 per `version` in the lines). Layout: `projects/<cwd with / and . replaced by ->/<sessionId>.jsonl`, plus a `memory/` dir. 39 files, 7.7 MB total, file name equals `sessionId` in every case.

**Line types seen:** `assistant`, `user`, `system` (subtypes `turn_duration`, `stop_hook_summary`, `local_command`), `attachment`, `queue-operation`, `file-history-snapshot`, `ai-title`, `last-prompt`, `mode`, `permission-mode`, `atis-latch`, `continued-in` (`sessionId`, `continuedInSessionId`, `timestamp`), `agent-name`, and `cost-state`.

**Usage lives only on `type:"assistant"` lines.**
- Line level: `timestamp` (ISO-8601 ms Z), `requestId`, `sessionId`, `isSidechain`, `apiBlockIndex`, `cwd`, `version`, `entrypoint`, `isApiErrorMessage`.
- `message`: `id` (`msg_…`), `model`, `stop_reason`, `usage`.
- `message.usage`:
  - Counters: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`.
  - Cache split: `cache_creation{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`.
  - Output detail: `output_tokens_details{thinking_tokens}`. Thinking is a subset of `output_tokens`, not additive.
  - Server tools: `server_tool_use{web_search_requests, web_fetch_requests}`.
  - Classification: `service_tier` ("standard"), `speed` ("standard"; the "fast" value comes from the docs and T3, not the probe), `inference_geo` ("not_available").
  - Other: `iterations[]` (entries with `type:"message"` and a per-iteration usage copy), `fallback_credit`.
- `<synthetic>` model lines (2 of 117) have null `speed`, `service_tier` and `iterations`, and zero tokens. Skip them.
- No `costUSD` field exists in the 2.1.284 assistant lines; it is legacy. ccusage and T3 still read it when present (ccusage `cost.rs`; T3 `usageTranscripts.ts` ~L140).

**Duplication.**
- Each assistant message is written once per content block (`apiBlockIndex` 0, 1, …), and every copy repeats the full `usage`.
- In the probe, 57 of 59 `(message.id, requestId)` keys were duplicated within a file, and all copies were identical (0 differing). Cross-file duplicates: 0.
- Summing without dedupe overcounts about 2x (T3 measured about 2.4x).
- ccusage keeps one entry per `(message.id, requestId)`, preferring non-sidechain and then the larger token total. If a key lacks `requestId`, it uses message id + session + timestamp.
- ccusage also drops sidechain replays: same `message.id`, different `requestId`, `isSidechain:true`, which would otherwise duplicate the parent's cache reads.
- Source: ccusage `rust/adapters/claude/src/README.md` and `lib.rs` (`should_replace_deduped_entry`, `push_deduped_entry`).

**Subagents (from docs and ccusage; NOT verifiable in the probe, which has none).**
- Layout: `projects/<p>/<sessionId>/subagents/agent-<agentId>.jsonl` plus `.meta.json`; per code.claude.com `claude-directory`.
- Their lines carry `isSidechain:true`, and `sessionId` points at the parent.
- Their API usage is billed separately from the main file. Loom must scan `projects/**/*.jsonl` recursively. `tool-results/` and `memory/` hold non-transcript files.
- ccusage walks recursively and treats both flat and nested layouts as sessions.

**Append-only or rewritten.**
- All 39 probe files end with `\n`, and their lines are consistent with appending.
- Docs: Claude may set aside a prior transcript as `<session>.orphaned-<ts>-<suffix>.jsonl` or `<session>.jsonl.superseded-<ts>` rather than overwrite it. These appear in the `.jsonl*` namespace and need an explicit decision (see §4).
- `/clear` starts a new sessionId and writes `continued-in`; resume appends to the same file (the probe shows one file with 2 cost-states after a resume).
- ccusage warns that a resumed or copied response can appear in several transcripts. Dedupe by `requestId` across files.
- T3 treats transcripts as append-only but guards against rewrites with a 64-byte tail hash. Loom should do the same.

**`cost-state` lines (new, undocumented; seen in 43 lines across 35 probe files).**
- Fields: `sessionId`, `totalCostUSD`, `modelUsage{<model>:{inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, costUSD}}`, `totalAPIDuration`, `totalDuration`, `startTime`, `hasUnknownModelCost`.
- It is a cumulative per-session snapshot written after each turn (e.g. 0.0144, 0.0181, 0.0222, 0.0271 within one file). There is no per-message timestamp.
- Its input and cache totals exceed the transcript's (e.g. 942 vs 40 input tokens), because auxiliary calls are included. It reproduces the list-price formula exactly: 916 in, 84 out, 23482 cr, 9303 1h-cache at Haiku 4.5 rates gives $0.0222902, which matches.
- Use it only as an optional cross-check; the format is private and may change.

**Other local sources.**
- `<config>/.claude.json` `projects.<cwd>.lastCost`, `lastModelUsage` and `lastTotal*Tokens` hold only the last session per project, written at exit. They are weak.
- `stats-cache.json` is documented as "aggregated token and cost counts shown by `/usage`" (claude-directory). It is absent in the probe profile, so I could not confirm its schema. Treat it as an unverified, version-dependent private file and do not depend on it.
- `/usage` computes from local session history only ("approximate and computed from local session history on this machine", costs doc). There is no local rate-limit state file. A grep of the probe for `ratelimit|five_hour|resets_at|utilization` hit only `.claude.json`'s `cachedExtraUsageDisabledReason` (a string).

**Statusline JSON** (code.claude.com/docs/en/statusline):
- Fields: `cost.total_cost_usd` (client-side list-price estimate, reset by `/clear` since v2.1.211), `cost.total_duration_ms`, `context_window.*`, `prompt_cache{…}`, `transcript_path`, `session_id`, and `rate_limits.five_hour|seven_day{used_percentage, resets_at(epoch s)}`.
- `rate_limits` appears only for claude.ai Pro/Max subscribers, only after the session's first API response, and each window may be absent.
- Per a community issue, it is a stale snapshot attached to the session's last response, not a live check.
- It is delivered by running a configured `statusLine` command. That is a new process per update (300 ms debounce), and a custom status line removes most footer hints. Per D-20 that is a user decision.
- Loom already injects `--settings <json>` with hooks (`ProviderLaunchProfile.swift:103-132`). A `statusLine` there would override the user's own status line (flag settings take precedence over user settings). I did not test this.

**OpenTelemetry** (monitoring-usage):
- Opt-in via `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus exporter env vars set on the Claude process. Metrics are `claude_code.cost.usage` and `claude_code.token.usage`, with `speed`, `model` and `query_source` attributes.
- There is no file exporter for metrics, so this needs a collector or env changes. It is not suitable.

**Limits, no network, no behavior change.** There is no such source. T3 gets limits through the Claude Agent SDK (`get_usage` and streamed `rate_limit_event`), because T3 owns the SDK session. Loom hosts the real CLI, so that is unavailable.

## 2. Pricing

Source: https://platform.claude.com/docs/en/about-claude/pricing, fetched 2026-10-07 (the page shows no date). Cost-tracking basis: code.claude.com/docs/en/costs ("computed locally from token counts at list price").

| Model | Input $/MTok | 5m write | 1h write | Cache read | Output |
|---|---|---|---|---|---|
| Fable 5.1 (and Mythos 5.1) | 10 | 12.50 | 20 | **0.25** | 50 |
| Fable 5 | 10 | 12.50 | 20 | 1 | 50 |
| Opus 5.5 | **4** | 5 | 8 | **0.20** | 20 |
| Opus 5 / 4.8 / 4.7 / 4.6 / 4.5 | 5 | 6.25 | 10 | 0.50 | 25 |
| Opus 4.1 / 4 | 15 | 18.75 | 30 | 1.50 | 75 |
| Sonnet 5.5 / Sonnet 5 | 2 | 2.50 | 4 | 0.20 | 10 |
| Sonnet 4.6 / 4.5 / 4 | 3 | 3.75 | 6 | 0.30 | 15 |
| Haiku 4.5 | 1 | 1.25 | 2 | 0.10 | 5 |
| Haiku 3.5 | 0.80 | 1 | 1.60 | 0.08 | 4 |

- **Cache multipliers** are 1.25x base for a 5m write, 2x for a 1h write, 0.1x for a read. The exceptions are 0.025x on Fable/Mythos 5.1 and 0.05x on Opus 5.5.
- **Fast mode** (`usage.speed:"fast"`): Opus 5.5 is $8 in / $40 out; Opus 5 and 4.8 are $10 / $50. Cache multipliers stack on top of the fast base. Fast mode is unsupported on Opus 4.7 and 4.6.
- **Data residency**: `inference_geo:"us"` gives a 1.1x multiplier on all categories for 4.6 and later. The transcript field `usage.inference_geo` ("not_available" in the probe) can feed this. Claude Code applies the same 1.1x in its own figure (costs doc).
- **Long context**: no premium for 4.6 and later (full 1M context at standard rates). ccusage's LiteLLM-derived table still models an above-200k tier for older models.
- **Web search** is $10 per 1,000 searches, via `server_tool_use.web_search_requests`. Web fetch has no extra charge.
- **Batch** is a 50% discount, never applicable to transcripts.
- **Tokenizer**: Claude 4.7 and later uses a new tokenizer (about 30% more tokens for the same text). This does not affect per-token pricing but explains token-count jumps across models.
- **Cache TTL**: 1h on a subscription, 5m on API key or on usage credits. Price by the `cache_creation.ephemeral_*` split, not a single write rate.
- **Label**: cost is an API-equivalent estimate. Subscription users do not pay per token, and the CLI's own `modelPricing` managed setting may differ.
- **Local vs official check**: my formula reproduces `cost-state.costUSD` to 1e-7 for Haiku 4.5.
- **Table maintenance**: the table must be hard-coded with an "as of 2026-10" date and a user-visible unknown-model fallback (tokens only, cost "—"). Do not fetch it. ccusage and T3 use the LiteLLM JSON, but that needs network and extra trust.

## 3. Prior art

**ccusage** (ryoppippi/ccusage, now a Rust workspace with `adapters/claude`):
- Discovery: `CLAUDE_CONFIG_DIR` (comma-separated, replaces defaults), else `~/.config/claude` and `~/.claude`, `projects/` scanned recursively (`paths.rs`).
- Parse: parallel, size-balanced chunking, `memchr` gating, malformed lines skipped, `--since` skips files by mtime, and costs support `auto|calculate|display` modes.
- Dedupe and sidechain: see §1.
- Pricing: LiteLLM table, with an auto-update workflow.
- Blocks (`blocks.rs:52-104`): entries sorted by timestamp. A block starts at the first entry floored to the hour (UTC), lasts 5 h, and a new block opens when `since_start > 5h` or `since_last > 5h`, with a gap block in between. This is an approximation of Claude's server-side window, not Anthropic's accounting.
- It also parses "Claude AI usage limit reached|<epoch>" from `isApiErrorMessage` lines to learn reset times (`usage_limit_reset_time_from_line`). That format is legacy and may no longer exist in current versions (unverified).
- Caveat in its docs: Claude retains logs only 30 days by default.

**T3 Code** (pingdotgg/t3code, `apps/server/src/usage/`):
- It does **not** use the CLI; it embeds the Agent SDK, so limits come from SDK `get_usage` and `rate_limit_event` (`provider/claudeUsageLimits.ts`). It checks at most once per 5 minutes per environment (`docs/user/usage.md`).
- Scan: walk `*.jsonl` with 32 parallel `stat` calls, filter by mtime >= since, then parse. A substring gate (`line.includes('"usage"')`) skips about half the lines before `JSON.parse`, "worth about an order of magnitude" (`usageTranscripts.ts` ~L68). Files over 8 MiB are streamed.
- Cache (`usageScanCache.ts`), described in its comments as the "Speed Up Usage Calculation Caching" work:
  - A durable per-file cache keyed by `(size, mtime)`.
  - A parse position with `resumeOffset` (just past the last complete newline), a 64-byte tail guard hash (FNV-1a) as a rewrite tripwire, and separate `tailRecords` for a partial last line (re-read next scan, not double counted).
  - Positional, interned rows: a 30-day cache is "under six" MB, versus tens of MB with object-per-record.
  - Reported performance: about 3.5 s for a cold 30-day scan versus about 11 ms to reload the cache.
  - Version-suffixed cache file names so an old server does not clobber a newer cache.
- Aggregation: `(day, hourStart?, provider, model)` buckets; day resolved in the report timezone via `Intl`, with a 15-minute-slot cache.
- Pricing: LiteLLM, with fast and ultrafast speed rates; users can override per-model rates and alias models.
- UI (reference screenshot): Cost / Tokens / Limits tabs, Past 24h/7d/30d/90d, total plus "API estimate" label, daily area chart, Totals (processed, cached input, uncached input, output, cache savings), cost by type, cost by speed, and a Breakdown table by Model or Day.

**Other apps** (web search only; none verified in depth):
- Menu-bar trackers (clabar, mnapoli/claude-usage-bar, ClaudeUsageBar, Claude-Usage-Tracker) get limits by Claude OAuth against Anthropic's API (clabar), scraping claude.ai in a hidden browser (claude-usage-bar, 5-minute refresh), or pasted browser cookies (ClaudeUsageBar). All hit Anthropic's servers, which is the load D-32 forbids.
- Statusline-script apps read `rate_limits` from stdin and write it to a file for other tools (blog posts, tommcfarlin.com among others).
- I found nothing on how Claude Desktop, cmux, Conductor or Crystal/Nimbalyst compute usage.

## 4. Proposed design for Loom

**Placement.**
- A new `LoomCore` type (e.g. `ClaudeUsageIndex`) with a provider-generic record. LoomCore already links `sqlite3` (`Package.swift`, `SessionCatalog.swift` imports `SQLite3`).
- Add a `provider` column so Codex can be added later (D-28 freeze).
- The Settings page replaces the current 25-line `SettingsView.swift`, and the footer replaces `SidebarFooter` (`SidebarView.swift:113-137`).

**Config dir discovery** (follow the same logic the launcher uses, not a fresh guess):
1. Explicit test or evidence profile: `ProviderToolchain.profileDirectory` (`ProviderToolchain.swift:6-9`, set from `--claude-config` at `AppDelegate.swift:433`).
2. Production: `CLAUDE_CONFIG_DIR` from `toolchain.environment` (the user's resolved terminal environment; `SessionRuntime.swift:652`).
3. Else `~/.claude` (`SessionRuntime.swift:681-682`).
4. Do not read `~/.config/claude` unless the user's `CLAUDE_CONFIG_DIR` points there (ccusage adds it; Loom launches Claude with the same env, so mirror that exactly).
5. Resolve symlinks, and require that `projects/` exists and is owned by the user. `ClaudeRegistryReader` already does `O_NOFOLLOW` and uid and mode checks for `sessions/`; reuse its stance.
6. Only the user's own profile is ever the production target. Evidence and tests use `--claude-config` roots.

**Index** (`usage-index.sqlite3` in the data root, separate from the catalog DB, disposable and rebuildable):
- `file(path PK, dev, ino, size, mtime_ns, offset, guard_len, guard_hash, last_seen)`.
- `msg(key INTEGER PRIMARY KEY, file_id, ts_ms, session, model_id, in, out, cw5, cw1, cr, web_search, speed, geo, sidechain)`, WITHOUT ROWID or equivalent.
- `INSERT … ON CONFLICT DO UPDATE WHERE excluded.total > msg.total` implements ccusage's keep-the-larger rule, with a non-sidechain preference.
- `key` is a 64-bit hash of `message.id` (plus `requestId` when present). To collapse sidechain replays (same `message.id`, different `requestId`), hashing `message.id` alone is simpler and probably more robust than ccusage's special case. Verify with the fixtures below.
- Optionally a `day_agg(day, model, provider, …)` roll-up kept after raw rows are pruned, so history older than the raw-retention window stays visible.
- Raw-row size: assume about 80 bytes per row, so 1M messages is about 80 MB. A heavy user at 10k messages/day over 90 days is about 72 MB. Prune raw rows beyond a configurable window (default 90 days) and keep daily aggregates beyond that. This is an estimate to confirm against a generated corpus.

**Incremental scan:**
- Per file, stat `(dev, ino, size, mtime)`.
- Unchanged: skip. Grown: seek to `offset`, verify the 64-byte guard hash ending at `offset`, read from there. Hash mismatch, `size < offset`, or a changed inode: treat as rewritten or rotated, delete that file's rows and re-parse from 0.
- Parse only whole lines up to the last `\n`; carry the partial tail unconsumed (do not advance `offset` past it, and do not insert records from it). This avoids T3's separate tail-record machinery.
- A cheap byte-level `memmem` gate for `"usage"` and `"type":"assistant"` before any JSON decode. Use `JSONSerialization` or a bounded field extractor only on candidates, and cap a line at about 16 MiB.
- Run on a low-QoS background queue and yield between files.
- Skip files whose mtime is older than the scan window on a cold start; deletion of a transcript by Claude leaves Loom's rows (they are history).
- Orphaned and `.superseded-*` files: either exclude them or include them with key dedupe. Excluding is safer for correctness; flagged as a decision below.

**Refresh triggers, none timer-based:**
- The `Stop` hook already delivers `transcript_path` and session id (`ClaudeHook.swift:365,395`) and Loom already subscribes to hook events. On Stop (and StopFailure), re-scan just that file, with debounce and coalescing. Today Loom does not use `transcriptPath` anywhere other than parsing it.
- Opening Settings, and app activation (`AppDelegate.swift:209`), trigger a full incremental pass over files whose stat changed.
- No timer when hidden.
- The sidebar footer reads the cached aggregate and updates on index revision change, not by polling.
- Cold start: show "Indexing…" with progress; never block launch.

**Cold scan estimates** (not measured; to be checked on a generated corpus):
- 2 GB of JSONL read at a warm-cache rate of 2 to 3 GB/s is about 1 s of I/O.
- If about half the lines pass the gate (T3's ratio) and Foundation decodes at about 100 to 300 MB/s, that is about 3 to 10 s of single-thread CPU on a background queue.
- Memory stays bounded by streaming 1 to 4 MiB chunks plus the SQLite page cache (single-digit MB).
- T3's measured 3.5 s for a cold 30-day window and 11 ms for a warm cache set the right expectation. With the default 30-day retention, the cold scan is usually well under 1 GB.

**Aggregates:**
- Per day (local timezone, resolved at query time) x model: tokens by type, estimated cost, message count, session count.
- Cache share: `cr / (in + cw + cr)`.
- 5-hour block: apply ccusage's algorithm to message timestamps at query time (no stored blocks). Label it "recent activity window (approximate)", not the plan limit.
- Costs are computed at query time from a static table keyed by model id with alias and date-suffix normalization, so a table update re-prices history without re-parsing.

**UI.**
- **Sidebar footer** (compact): today's tokens, optionally with est. cost (`~$X`), and the active 5-hour block's tokens. Show tokens as the primary figure and cost as the muted secondary.
- **Settings > Usage** (usage-first):
  - Totals row: processed, cached input, uncached input, output.
  - Daily bars: tokens by day, then model.
  - Breakdown by model and by day.
  - Sessions (project and title from the catalog).
  - Cache share.
  - Est. cost as a secondary column or toggle labelled "API-equivalent estimate; subscription is not billed per token".
  - Unknown models are listed with tokens and cost "—".
  - Period buttons: 24 h, 7 d, 30 d, 90 d (as in the T3 reference).
  - Provider-generic data model, Claude only today.
- **Limits tab**: not built. Show a note that plan limits need a status-line setting (see decisions).

## 5. Test fixtures

Build synthetic profiles at test time under a temp directory (e.g. via `FileManager.temporaryDirectory`), passed as the config root. Never touch `~/.claude`, the installed apps, or `~/Library/Application Support/Loom*`. Follow the existing `loom-catalog-fixture` and `loom-fake-provider` pattern; the fake provider already reads `CLAUDE_CONFIG_DIR` (`Sources/loom-fake-provider/main.swift:50,107`). Tests belong in `Tests/LoomCoreTests`.

Fixture generator: a small Swift helper emitting `projects/<encoded cwd>/<uuid>.jsonl` and `projects/<enc>/<uuid>/subagents/agent-<id>.jsonl`, with lines in the shapes of §1 (field names only, synthetic content). Cases:

1. **Per-block duplicates**: the same `message.id` + `requestId` across 2 to 3 lines with identical usage, expecting a single count.
2. **Streaming partials**: duplicates with different `output_tokens`, expecting the largest to win (ccusage's rule).
3. **Partial last line**: truncate the final line mid-JSON. Expect no record and no offset advance; after appending the rest and `\n`, exactly one record.
4. **Append growth**: scan, append N lines, rescan; only the new bytes are read and totals are exact.
5. **Rewrite and rotation**: shrink the file, replace it (new inode), or alter bytes before the offset; expect a full re-parse with no double counting.
6. **Sidechains**: a `subagents/agent-*.jsonl` file with its own message ids (counted) and one replaying a parent `message.id` under a new `requestId` with `isSidechain:true` (dropped).
7. **Cross-file duplicates**: the same key in two files (resume or copy) counts once.
8. **Synthetic and error lines**: model `<synthetic>` with zero tokens, and an `isApiErrorMessage` line, both ignored.
9. **Unknown model**: tokens counted, cost nil and flagged.
10. **Malformed content**: invalid JSON line, a binary byte, an oversized line, a missing `usage`, a missing `timestamp`, negative or non-integer counters (clamped or skipped, no crash).
11. **Cache split**: `cache_creation` present with 5m/1h mix versus only `cache_creation_input_tokens` (legacy; treat all as 5m).
12. **Fast and geo**: `speed:"fast"` on an Opus 5.5 line (check the $8/$40 premium and the 5m, 1h and read multipliers on top); `inference_geo:"us"` (1.1x).
13. **Day boundaries**: timestamps at 23:59:59.999Z and 00:00:00Z, with a non-UTC timezone, bucketed correctly.
14. **Orphan and `.superseded` files**: confirm the chosen include or exclude rule.
15. **Cost-state cross-check** (optional): include a `cost-state` line and assert the documented difference rather than equality.

Pricing arithmetic can be pinned to hand-computed values, such as the Haiku 4.5 example in §1 giving $0.0222902. A volume test uses a generated corpus (about 1 GB) in the Mac-idle run window to confirm the first-scan time and memory. Acceptance for "matches Claude's records on test data" should use tokens (exact, deduped) as the primary comparison and cost with a stated tolerance.

## Risks and unknowns

- **Subagent file layout** is from docs and ccusage; the probe has no subagent runs, so field names there are unverified for 2.1.284. A small real-Claude check with a subagent turn in the isolated profile is the smallest next verification.
- **Format drift.** The transcript format is private and changes (e.g. `cost-state`, `apiBlockIndex`, `iterations` are recent; `costUSD` is gone). Parse defensively, tolerate missing fields, and put a schema version in the index.
- **Undercount versus Claude's own total.** Auxiliary calls are invisible in transcripts, and on tiny sessions the gap was 14%. It should shrink on real sessions but is unmeasured.
- **Resume and `/clear` accounting.** Whether `cost-state` is carried or reset across resume is unverified, so do not rely on it.
- **`stats-cache.json`** is documented but absent in the probe; its schema is unknown.
- **Retention.** If a user lowers `cleanupPeriodDays` or purges projects, Loom's raw rows could outlive the source. Decide whether the index mirrors deletions. CP4 (conversation deletion) and the usage index should be reconciled: deleting a Loom conversation should probably not delete usage history, and the contract says provider-retention loss must be explicit.
- **Scope.** Contract §13 puts "importing pre-existing provider history" out of scope. Whether the usage view covers all transcripts in the config dir or only Loom-managed conversations is undecided (below).
- **Pricing table.** Hard-coded prices go stale; unknown models need an explicit fallback. Fable/Mythos 5.1 and Opus 5.5 have non-default cache read multipliers; do not assume 0.1x.
- **Performance numbers** above are estimates, not measurements.
- **5-hour block** is a heuristic and can diverge from Anthropic's accounting (a community report shows sessions spanning windows). Do not present it as a limit.

## Decision points for the user (with recommendation)

1. **Plan limits (5h/weekly).** Options: (a) skip; (b) add a `statusLine` command to Loom's inline `--settings` that writes `rate_limits` to a Loom file; (c) network/OAuth. Recommendation: **(a) for now**, show only the labelled local 5-hour activity block. (b) is the only local route but is a D-20 behavior change: it overrides the user's own status line, hides footer hints, spawns a process per update, and works only for Pro/Max after the first response. If wanted later, make it an opt-in Settings toggle with a statusLine that only writes a file and prints nothing (not tested).
2. **Usage scope.** Count all Claude transcripts under the active config dir (like ccusage and T3) versus only Loom-managed conversations. Recommendation: **all transcripts under the active config dir**, labelled as "this Claude profile", since the point is to match Claude's own `/usage`. This touches the contract §13 "importing history" line, which I read as being about showing history as conversations, not aggregating counters.
3. **History window.** Raw rows for 90 days, daily aggregates kept longer. Recommendation: default **90 days raw plus aggregates kept**, since Claude's own default retention is 30 days and ours should outlive it.
4. **Orphan and `.superseded` transcripts.** Recommendation: **exclude** (key dedupe would otherwise double count them), and revisit after a fixture or real-run check.
5. **Cost presentation.** Recommendation: tokens primary; cost secondary, always prefixed "est." with the subscription caveat, hidden for unknown models.
6. **Pricing table updates.** Static table with an as-of date, updated by release (no network). A user override per model (as in T3) is optional and can wait.
7. **Index schema.** Per-message SQLite (recommended, exact dedupe and re-pricing) versus per-file-per-day aggregates only (smaller, but weaker dedupe across files and no re-pricing).
8. **Agreement on "matches Claude's records".** Recommendation: define it as tokens equal after dedupe against the transcripts themselves, and cost within a stated tolerance of `cost-state` for sessions with no auxiliary calls; do not promise equality with `/usage`.

Key files referenced:
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ProviderToolchain.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ProviderLaunchProfile.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/SessionRuntime.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ClaudeHook.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ClaudeRegistry.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SidebarView.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SettingsView.swift
- /Users/gencberke/Documents/github/loom-dev/Sources/loom-app/AppDelegate.swift
- /Users/gencberke/Documents/github/loom-dev/DECISIONS.md (D-20, D-32)
- /Users/gencberke/Documents/github/loom-dev/design/references/t3-code-usage-reference.png
- Isolated profile inspected (field names only): `~/Library/Application Support/Loom-Dev/probe/claude-config/projects`