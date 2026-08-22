# Codex 微信桥接

[![GitHub Stars](https://img.shields.io/github/stars/xiao0xiao0/codex-wechat-bridge?style=social)](https://github.com/xiao0xiao0/codex-wechat-bridge)

在 Windows 上把 Codex 桌面任务连接到微信 ClawBot：任务结束后发送微信通知，也可以从微信引用通知继续原任务、创建新对话或创建保留历史的对话分支。

> 当前稳定版：`0.9.30`。这是社区项目，不是 OpenAI 或腾讯官方产品。

## 功能

- Codex 完成、暂停和失败时发送微信通知。
- 在微信引用任务通知，继续对应的 Codex 桌面任务。
- `/新建 任务内容` 创建独立对话，不创建新项目目录。
- 引用任务通知后发送 `/分支 任务内容`，复制完整对话历史并创建桌面可见分支。
- `/状态` 查看执行中、暂停和最近任务，执行中任务会显示最近的用户可见进展。
- 长结果按段落安全分段，引用任意一段都能续接同一任务。
- 可选发送完成附件；每个文件独立排队，默认关闭自动发送。
- `/清空` 可归档未发送积压并从当前时刻重新开始通知。
- 微信轮询游标损坏时自动隔离、自愈，并丢弃恢复请求中的历史命令，防止断线重放。
- 不需要安装或运行 OpenClaw。

## 环境要求

- Windows 10/11
- Codex 桌面应用
- PowerShell 7（`pwsh`）
- 微信中的 ClawBot/微信机器人入口
- 安装和运行期间 Windows 保持解锁；从微信续接现有任务时 Codex 窗口需要可操作

## 推荐安装

最简单的方式是克隆或下载本仓库后，在仓库根目录用 PowerShell 7 运行：

```powershell
pwsh -NoProfile -File .\install.ps1 -Configure -StartNow -EnableRelay
```

也可以手动安装：

```powershell
codex plugin marketplace add xiao0xiao0/codex-wechat-bridge
codex plugin add codex-wechat-bridge@codex-wechat-bridge

$plugin = Get-ChildItem "$env:USERPROFILE\.codex\plugins\cache\codex-wechat-bridge\codex-wechat-bridge" -Directory |
  Sort-Object Name -Descending |
  Select-Object -First 1

pwsh -NoProfile -File "$($plugin.FullName)\scripts\Connect-WeChatBridge.ps1"
pwsh -NoProfile -File "$($plugin.FullName)\scripts\Install-WeChatBridgeService.ps1" -StartNow
pwsh -NoProfile -File "$($plugin.FullName)\scripts\Enable-WeChatCodexRelay.ps1"
pwsh -NoProfile -File "$($plugin.FullName)\scripts\Get-WeChatBridgeDoctor.ps1"
```

扫码绑定后，先在微信中给 ClawBot 发送任意一条消息，让桥接取得当前会话上下文。然后运行诊断脚本，预期看到主监控和完成监控均为“正常”。

完整的分步教程、更新、卸载和排障见 [中文安装教程](docs/安装教程.md)。本版的功能说明、升级重点和已知限制见 [v0.9.30 中文发布说明](docs/releases/v0.9.30.md)。

## 微信用法

无需引用：

- `/在线`：检查桥接在线状态
- `/桥接状态`：查看投递与执行队列
- `/状态`：查看当前任务及最近进展
- `/状态 最近`：查看最近任务
- `/状态 完整`：查看最近任务及结果摘要
- `/诊断`：诊断后台进程、Codex 和积压
- `/清空`：归档尚未发送的文字和附件，从当前时刻继续通知
- `/帮助`：显示帮助
- `/新建 任务内容`：新建独立 Codex 对话

需要引用桥接发出的 `【已完成】`、`【已暂停】` 或 `【执行失败】` 通知：

- 直接回复文字：继续被引用的任务
- `/分支 任务内容`：创建保留历史的新对话分支
- `/附件`、`/附件 重试`、`/附件 <序号>`、`/附件 全部`：查看、重试或补充发送该任务附件

## 安全和隐私

- 微信凭据用 Windows DPAPI 加密，状态只保存在 `%LOCALAPPDATA%\CodexWeChatBridge`。
- 仓库不包含任何人的凭据、微信用户 ID、消息、Codex 任务 ID、日志或本机绝对路径。
- 只有扫码绑定的微信用户可以执行命令。
- 普通未引用消息不执行；仅 `/新建` 是明确允许的不引用执行命令。
- 附件上传到微信 CDN，默认关闭，需使用者明确开启。
- 损坏的微信同步游标会被隔离备份；恢复请求返回的历史消息只计数、不进入执行队列。
- 本项目调用腾讯微信 iLink/ClawBot 网络接口；其可用性和兼容性可能随上游变化。

详见 [安全说明](SECURITY.md) 和插件内部的 [第三方声明](plugins/codex-wechat-bridge/THIRD_PARTY_NOTICES.md)。

## 开发与验证

```powershell
pwsh -NoProfile -File .\tests\Validate-PublicRelease.ps1
```

验证范围包括插件清单、PowerShell 语法、公开包敏感字面量和 marketplace 结构；不会登录微信、发送消息或创建 Codex 任务。

## 支持项目

如果这个项目帮你减少了守在电脑旁等待 Codex 的时间，欢迎前往 [GitHub 仓库](https://github.com/xiao0xiao0/codex-wechat-bridge)，点击右上角的 **Star**。Star 完全自愿，不会解锁额外功能，也不会影响正常使用；它只是帮助更多有相同需求的人发现这个项目。

## 许可证

[MIT](LICENSE)
