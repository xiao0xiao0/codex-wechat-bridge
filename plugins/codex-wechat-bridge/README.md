# Codex WeChat Bridge

This Windows Codex plugin sends task lifecycle notifications to the official WeChat ClawBot channel and relays controlled commands without installing OpenClaw. Its primary commands continue a quoted task, create a desktop-visible conversation, and create a full-history branch of a quoted conversation.

## Security defaults

- WeChat credentials and context tokens are encrypted with Windows DPAPI for the current user.
- Only the WeChat user who scans the login QR code is accepted.
- Inbound messages are always stored in a local audit queue.
- Only the QR-authorized WeChat user can execute messages, and only after the relay is explicitly enabled. Continuation and branch messages must quote a bridge-generated lifecycle notification; `/新建 任务内容` is the explicit unquoted creation exception.
- Existing-task continuation submits through the Codex desktop composer so the desktop remains the sole writer for that task. It scans all visible Codex windows for up to 30 seconds, selects only the window whose visible task title matches the quoted target, and targets that window's `ProseMirror` input control through Windows UI Automation; if any check fails, nothing is submitted. It requires Windows to be unlocked and the Codex window to be operable, but it cannot create a competing App Server writer.
- New conversations and branches use the official Codex App Server `thread/start` and `thread/fork` methods. After the first turn is accepted, WeChat receives `开始处理`; the bridge reports success only after that turn finishes and the exact id and name appear in the interactive Codex Desktop task catalog. If the short-lived App Server exits unexpectedly, a durable Chinese paused/failed notification is sent or queued, so the command never remains indefinitely at `等待执行`.
- Notification failures never block or continue a Codex turn.
- Completion monitoring never replays an existing or truncated rollout from byte zero. Native conversation forks also suppress every copied lifecycle event whose turn id already belongs to the source task. If that source rollout is unavailable during a bridge-owned zero replay, the monitor fails closed and admits only the exact new turn id recorded by the bridge; normal incremental turns continue from the saved byte cursor. Completion events older than the monitor epoch or freshness window are suppressed, and a per-scan circuit breaker limits unexpected bursts.
- Logs redact bearer tokens.
- Duplicate inbound WeChat message IDs are ignored, and daily/worker logs have bounded retention.
- The scheduled task starts when available and restarts the monitor after unexpected exits.

State is stored under `%LOCALAPPDATA%\CodexWeChatBridge` unless `CODEX_WECHAT_BRIDGE_HOME` is set.

## Setup

Run with PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\Connect-WeChatBridge.ps1
pwsh -NoProfile -File .\scripts\Install-WeChatBridgeService.ps1 -StartNow
pwsh -NoProfile -File .\scripts\Get-WeChatBridgeStatus.ps1
pwsh -NoProfile -File .\scripts\Send-WeChatBridgeTest.ps1
pwsh -NoProfile -File .\scripts\Enable-WeChatCodexRelay.ps1
```

After QR confirmation, send any message to ClawBot once. The monitor captures the fresh conversation token and replies with a connection acknowledgement.

## Controlled two-way relay

Every accepted inbound WeChat message is placed under `inbox/`. After opt-in, only text that quotes a bridge-generated lifecycle notification can continue its named Codex conversation; `/codex <task>` remains as a backward-compatible text form but is subject to the same quote requirement. Existing conversations use the Desktop-owned composer; brand-new conversations use a short-lived official App Server process. The background completion monitor sends results back to WeChat.

Execution receipts are distinct: `等待执行` confirms queue admission, `开始处理` is sent only after Codex records `task_started`, and `【已完成】` is emitted from the terminal rollout event.

Long-press the desired `【已完成】...` notification in WeChat, choose quote/reply, and type the continuation normally. Some WeChat clients replace the outbound `client_id`/item `msg_id` with a 19-digit server ID and return no preview text. The bridge first attempts exact ID matching, then derives the referenced send second from the numeric ID's high 32 bits using the current inbound message as a clock calibration and matches it against recorded completion delivery times. A bounded clock-jitter window is accepted only when the nearest conversation has a clear lead; close cross-conversation matches are rejected as ambiguous. This rule is the same whether one or several conversations have finished; ordinary unquoted messages are recorded but never executed.

Other commands:

- `/桥接状态` — bridge and relay status
- `/状态` — every genuinely running Desktop task, discovered from the live task catalog and verified against its latest rollout lifecycle boundary, including the latest user-visible progress commentary
- `/状态 最近` — recent conversations by status and name
- `/状态 完整` — recent conversations with result summaries
- `/诊断` — monitor, completion watcher, scheduler, Codex, queue, and log diagnosis
- `/在线` — liveness check
- `/帮助` — command help

Continuation and source-dependent commands must quote a bridge lifecycle notification:

- quoted text — continue the referenced task
- `/新建 任务内容` — create an independent desktop-visible conversation; no quote is required, no history is copied, and no project directory is inherited or created
- `/分支 [任务内容]` — quote a task notification and create a full-history Codex fork in the source task's current working directory

The default mode remains `queue_only` until `Enable-WeChatCodexRelay.ps1` is run. Once enabled, quoted completion replies are executable input from the authorized WeChat user. All task execution requires Codex Desktop to be open or launchable and Windows to be unlocked.
Quoted text resumes the task associated with the referenced notification. `/新建` uses one neutral bridge-owned working directory, rather than inheriting `new-chat` or another saved project; it creates no new project folder. `/分支` uses Codex's native history fork; it is a conversation branch, not a Git branch and not a Git worktree. The older English commands remain compatible aliases. Notifications and `/状态` use task names; opaque task IDs remain internal.

Completion delivery is handled by a dedicated background rollout monitor, so it also covers existing conversations that do not load or trust plugin Hooks. The monitor reads only lifecycle boundaries and the final assistant message, deduplicates by conversation and turn, then registers the conversation as a direct/quoted reply target.

On startup, newly discovered and truncated rollout files are baselined at their current end instead of replayed. Only completion events newer than the preserved monitor epoch and the configured freshness window are eligible for delivery; the default per-scan maximum is four.
Codex rollout timestamps without an explicit offset are interpreted as UTC, matching the desktop rollout writer instead of the Windows local timezone.

Completion messages use a compact Chinese layout:

```text
【已完成】conversation name
result summary
```

Attachment delivery is disabled by default because it uploads local files to Tencent's WeChat CDN. After the user explicitly approves and enables it, the bridge can send up to three existing local output files referenced by the final assistant message. Files are encrypted with AES-128-ECB and sent as `file_item` attachments; the default per-file ceiling is 100 MB. Text delivery and attachment progress are checkpointed separately so retrying an attachment does not duplicate the completion text.

If WeChat rejects proactive delivery with `ret=-2`, the bridge first attempts a non-executing empty-cursor context refresh. If no reusable context is available, it pauses delivery instead of retrying every poll, keeps the latest completion for each conversation in the outbox, and resumes automatically when the authorized user sends any new WeChat message. Superseded queued turns are preserved under `outbox-superseded/`.

## Upstream protocol notice

The transport follows the public protocol and request shapes in Tencent's MIT-licensed `openclaw-weixin` project. See `THIRD_PARTY_NOTICES.md`.
