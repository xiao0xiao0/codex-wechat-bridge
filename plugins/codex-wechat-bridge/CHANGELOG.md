# Changelog

## 0.9.22 - 2026-08-13

- Fails closed when a newly discovered native fork must be replayed from byte zero but its source rollout is unavailable: only the bridge-recorded new turn id may pass, so inherited lifecycle history cannot be published as fresh WeChat notifications. If the rollout appears before `turn/start` returns that id, the monitor holds the cursor at byte zero and retries instead of losing a fast completion.
- Preserves normal incremental monitoring for older forks whose source rollout has since disappeared; their saved byte cursor remains authoritative and new turns continue to notify.
- Records the missing-source condition in rollout monitor state so each affected fork logs one actionable warning instead of repeating the same warning on every appended event.

## 0.9.21 - 2026-08-13

- Rebuilds `/状态` from the union of the current Codex Desktop task catalog, visible rollout files, and the bridge registry instead of listing only tasks previously recorded by the bridge.
- Uses the latest rollout lifecycle boundary as the authoritative runtime state: `task_started` is running, `task_complete` is completed, and `turn_aborted` is paused. This prevents stale registry rows from remaining falsely `执行中`.
- Keeps the catalog as a discovery fallback for active tasks whose rollout has not yet been indexed, while the bridge registry supplies prior summaries rather than deciding execution state.
- Changes the default `/状态` view to list only genuinely running tasks with a count and current commentary. Paused, failed, and completed tasks remain available under `/状态 最近` and `/状态 完整`.

## 0.9.20 - 2026-08-13

- Sends a `开始处理` acknowledgement after `/新建` and `/分支` actually start a Codex turn, matching existing-task continuation instead of leaving WeChat at `等待执行`.
- Recovers fast App Server tasks that start and terminate between completion-monitor scans. A pending relay is replayed from byte zero once, while the existing fork turn-id baseline still removes copied history.
- Converts App Server output loss, timeout, interruption, and non-completed terminal states into durable Chinese lifecycle notifications. If WeChat is temporarily unavailable, the state notification is queued for retry and remains quote-routable.
- Adds a first-turn branch guard so ordinary prompts such as “测试分支功能” are handled as branch content rather than recursively inspecting, waiting for, or terminating the bridge that created the branch.

## 0.9.19 - 2026-08-13

- Prevents a native Codex conversation fork from replaying copied lifecycle events as fresh WeChat completion notifications. Only turns whose ids are not inherited from the source task can produce new branch notifications.
- Removes the premature `已创建` acknowledgement. New conversations and branches are reported as successful only after their first turn finishes and a scan-repaired interactive `vscode` task with the exact generated id and name is present in the Codex Desktop task catalog; validation no longer relies on an incomplete state-database-only listing.
- Re-checks rollout metadata when a newly created user task is first observed before its metadata header is fully available, avoiding a startup race that could otherwise leave it permanently unmonitored.

## 0.9.18 - 2026-08-13

- Fixes quoted continuation on current Codex Desktop builds where the focused editor exposes the UI Automation class list as `ProseMirror ProseMirror-focused` instead of the exact single class `ProseMirror`.
- Matches the stable `ProseMirror` class token while retaining exact task-title verification, visible bounds checks, enabled/focusable checks, and fail-closed submission behavior.

## 0.9.17 - 2026-08-13

- Adds Chinese-first WeChat commands: `/新建`, `/分支`, `/状态`, `/桥接状态`, `/诊断`, `/刷新`, `/在线`, and `/帮助`; the established English forms remain compatible aliases.
- Restores new-task and branch execution through the official Codex App Server `thread/start` and `thread/fork` methods, avoiding Desktop new-page UI automation and its partial-window failures.
- Marks bridge-created tasks as user-initiated Codex Desktop tasks, verifies the returned task source before submitting content, and archives a mismatched task without starting a turn.
- Defines `/新建 任务内容` as an independent conversation with no copied history and no new project directory, while keeping the internal working directory required by Codex.
- Defines quoted `/分支 [任务内容]` as an official full-history conversation fork in the same working directory. Git worktree commands remain a hidden compatibility feature and are no longer shown in normal help.
- Replaces raw App Server and Windows UI errors in WeChat failure messages with concise Chinese explanations while retaining technical details in local diagnostics.

## 0.9.16 - 2026-08-12

- Temporarily fails closed for `/new`, `/fork`, and `/worktree` after live validation showed that current Codex Desktop creation-page automation can expose intermediate UI states without a reliable completion acknowledgement. Existing-task continuation, notifications, task status, and attachments remain enabled.

- Replaces App Server-created `/new` tasks with Codex Desktop's project-free new-task page, so creation succeeds only when a user-visible desktop rollout exists.
- Simplifies `/new` to `/new prompt`; the legacy `/new name | prompt` form remains accepted.
- Requires `/fork` and `/worktree` to quote their source task before syntax validation, and removes the required task-name argument.
- Redefines `/fork [prompt]` as a desktop-visible copy of the source task's visible user/Codex conversation, excluding hidden reasoning and live tool state.
- Rejects `/worktree` immediately when the referenced task is not in a Git repository, without creating a directory or task.
- Rejects the still-visible source task header while targeting a new-task composer, reducing the chance of submitting creation text into the source task during slow navigation.
- Invokes and verifies Codex Desktop's `不在项目中工作` control before `/new` submission so the task is not grouped under the last active project.

## 0.9.15 - 2026-08-12

- Restores the `开始处理` WeChat acknowledgement for existing-task continuation after the desktop single-writer migration.
- Sends the acknowledgement only after the target rollout records a new `task_started` event, so `等待执行` remains a queue receipt rather than a false execution claim.
- Audits the start acknowledgement time and WeChat message id without making acknowledgement delivery failure interrupt the Codex task.

## 0.9.14 - 2026-08-12

- Fixes false `verified composer` rejections when `codex://` navigation takes longer than the initial delay or Codex has multiple desktop windows.
- Polls every visible Codex top-level window for up to 30 seconds and selects only the window containing both the exact target task header and a visible `ProseMirror` composer.
- Revalidates the target window after activation and still fails closed without entering text if the task changes.

## 0.9.13 - 2026-08-12

- Replaces estimated screen coordinates with Windows UI Automation targeting of Codex's visible `ProseMirror` composer.
- Verifies the visible Codex task header exactly matches the quoted target name before entering continuation text; mismatch or missing controls fails closed without submission.
- Records the desktop targeting mode and title-verification result in the inbound audit record.

## 0.9.12 - 2026-08-12

- Stops using an independent Codex App Server to continue an existing desktop task after confirming that concurrent writers can produce `already has an active writer` and temporarily block the task in Codex Desktop.
- Restores existing-task continuation through the desktop-owned composer, preserving the Codex desktop process as the sole writer; `/new` remains an App Server-created independent task.
- Treats desktop submission failure as not submitted and explicitly states that no second App Server will be started for the target task.

## 0.9.11 - 2026-08-12

- Stops the previous scheduled bridge instance and bridge-only child monitors before switching cache paths, preventing old and new plugin versions from polling the same WeChat account concurrently after an upgrade.
- Stores the generating bridge version, actual reply text, and outbound message ID in maintenance-command audit records, making `/tasks` and `/status` responses directly traceable.
- Includes the running bridge version in `/status` replies.

## 0.9.10 - 2026-08-12

- Replaces screen-coordinate continuation with official Codex App Server `thread/resume` plus `turn/start`, so quoted replies target the recorded conversation without depending on desktop focus or window layout.
- Fixes the `/new` and `/fork` callback-scope failure that could create an empty task and then report `Update-InboundRecord` as missing.
- Makes `/tasks` show the latest user-visible commentary for each running conversation while excluding private reasoning and raw tool output.
- Uses per-target relay workers so long-running tasks in different conversations no longer block each other.
- Preserves the prior 0.9.9 plugin snapshot under the local release archive before deployment.

## 0.9.9 - 2026-08-12

- Makes `/new 名称 | 内容` available without quoting a prior notification; it creates an independent persistent conversation in the most recently active existing project directory.
- Keeps quoted `/new` as an explicit way to choose the referenced conversation's project directory, without copying that conversation's history.
- Creates `/new` conversations through Codex App Server `thread/start` instead of the desktop new-path route, avoiding unintended new project/directory creation.
- Makes `/tasks` a current-attention list without completion summaries; adds `/tasks recent` and `/tasks full` for progressively more history detail.
- Keeps `/fork` and `/worktree` quote-authorized because they require an explicit source conversation or repository.

## 0.9.8 - 2026-08-12

- Fixes `/tasks` when the Codex task catalog contains a single match or mixed old/new status fields.
- Records successful `/ping`, `/status`, `/tasks`, `/doctor`, and `/help` requests as completed maintenance commands instead of leaving the misleading default `queued_only` state.
- Adds an offline regression for task-list formatting and unquoted read-only command handling.

## 0.9.7 - 2026-08-12

- Defers a quoted reply only when its target Codex task is busy, while continuing to dispatch queued replies for other idle tasks.
- Releases the global relay worker as soon as Codex confirms `task_started`; the independent completion monitor now owns terminal state and notifications.
- Reconciles submitted inbox records on task completion, pause, or failure, then automatically retries messages deferred for that same task.
- Prevents a long-running task from leaving unrelated WeChat commands stuck at “等待执行”.

## 0.9.6 - 2026-08-12

- Resolves explicit WeChat quote timestamps with a sub-second ambiguity window, allowing sequential completion notifications about one second apart to route correctly while exact/near-exact ties still fail closed.
- Learns the WeChat server message ID after the first explicit-time match, so later replies quoting the same notification route by exact ID.
- Serializes quotable task notifications at least three seconds apart, preventing simultaneous task completions from sharing the same server timestamp slot.
- Keeps unquoted messages and numeric-ID-only guesses blocked when multiple tasks are candidates.

## 0.9.5 - 2026-08-12

- Performs WeChat's `getConfig` → `sendTyping` handshake before each outbound message, using the latest inbound context token.
- Sends completion text before attachments and registers its reply route immediately.
- Sends attachments separately with checkpoints and a one-attachment-per-poll budget, so attachment failures cannot block later task notifications.
- Drains the outbox only once for each `刷新通知` inbound message, avoiding repeated attachment sends in the same fresh context window.
- Preserves queued 0.9.4 records and resumes their remaining attachments without duplicating completion text.

## 0.9.4 - 2026-08-12

- Bundles each completion summary and its attachments into one WeChat `sendmessage` call to reduce iLink's consecutive-message-window usage.
- Adds `/refresh` and the Chinese maintenance aliases `刷新通知`, `恢复通知`, and `补发通知`; these refresh and drain notifications without executing a Codex task or sending an extra acknowledgement.
- Keeps all notifications queued when iLink returns `ret=-2`, ready for automatic delivery after the next inbound WeChat message refreshes the conversation context.

## 0.9.3 - 2026-08-12

- Routes quoted replies primarily from WeChat's explicit `ref_msg.message_item.create_time_ms` when quote text and exact client IDs are unavailable.
- Disables numeric high-bit time guessing whenever more than one Codex task is a candidate; multi-task uncertainty now fails closed instead of choosing the nearest task.

## 0.9.2 - 2026-08-12

- Added a two-tier numeric WeChat quote matcher: 45-second precise routing remains preferred; up to 15 minutes is allowed only when the nearest task leads the second candidate by at least 2 minutes.
- Records unresolved quoted commands explicitly instead of leaving them in the generic inbox-only state.

## 0.9.1 - 2026-08-12

- Made WeChat queue/progress acknowledgements best-effort so transient SSL failures cannot cancel or falsely fail an already-submitted Codex task.
- Starts the serial relay worker before attempting the optional queue acknowledgement.

## 0.9.0 - 2026-08-12

- Added strict quote-authorized `/new`, `/fork`, and `/worktree` commands.
- Added desktop-native persistent task creation, App Server history forks, and bridge-managed detached Git worktrees.
- Added `/doctor`, scheduled-task restart recovery, log retention, and inbound message deduplication.
- Added paused and failed lifecycle states without replaying historical events.
- Added a shareable Windows marketplace package and Chinese installation guide.
- Preserved the 0.8.2 numeric WeChat quote-routing ambiguity safeguards and attachment delivery checkpoints.

## 0.8.2 - 2026-08-11

- Matched Tencent numeric quote IDs with a bounded 45-second time window and a 10-second ambiguity margin.
- Prevented close concurrent completion notifications from routing to the wrong task.
