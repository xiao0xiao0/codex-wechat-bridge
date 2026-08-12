# Codex 微信桥接安装说明

## 使用条件

- Windows 10/11，并安装 PowerShell 7 和 Codex 桌面应用。
- 微信中已具备腾讯 ClawBot/微信机器人入口。
- Codex 与微信登录均由使用者本人完成。本插件不会携带、导出或共享任何人的令牌。

## 安装

推荐从 GitHub marketplace 安装：

```powershell
codex plugin marketplace add xiao0xiao0/codex-wechat-bridge
codex plugin add codex-wechat-bridge@codex-wechat-bridge
```

然后从 Codex 插件缓存定位最新版本，依次运行扫码绑定、服务安装和双向执行授权。仓库根目录的 `README.md` 和 `docs/安装教程.md` 提供了可直接复制的完整命令；也可以克隆仓库后在根目录运行：

```powershell
pwsh -NoProfile -File .\install.ps1 -Configure -StartNow -EnableRelay
```

`-Configure` 会打开二维码绑定流程；`-StartNow` 会注册并启动当前 Windows 用户的后台计划任务；`-EnableRelay` 明确开启微信到 Codex 的执行权限。扫码后，先给机器人发送任意一条微信消息，让桥接取得当前会话上下文。

## 微信指令

只读命令无需引用：

- `/在线`：检查桥接是否在线。
- `/桥接状态`：查看投递和执行队列。
- `/状态`：查看当前执行中、暂停或失败的任务；执行中任务同时显示最近一条用户可见的阶段性进展。
- `/状态 最近`：查看最近任务的状态和名称。
- `/状态 完整`：查看最近任务及结果摘要。
- `/诊断`：诊断后台服务、Codex、PowerShell 和积压。
- `/帮助`：显示帮助。

继续任务以及需要明确来源的命令必须引用桥接发出的 `【已完成】`、`【已暂停】`、`【执行失败】` 或 `【已创建】` 通知：

- 直接输入内容：继续被引用的任务。
- `/分支 [任务内容]`：复制被引用任务已保存的完整对话历史，创建新的桌面任务；这不是 Git 分支。

`/新建 任务内容` 无需引用：它创建独立桌面任务，不复制旧对话，不继承 `new-chat` 或其他已保存项目，也不创建新项目目录。

## 安全与隐私

- 微信令牌和上下文使用当前 Windows 用户的 DPAPI 加密，保存在 `%LOCALAPPDATA%\CodexWeChatBridge`。
- 分享包不包含任何配置、凭据、消息、日志、任务编号或本机绝对路径。
- 只有扫码绑定的微信账号会被接受。
- 普通消息只记录、不执行；继续和 `/分支` 必须引用桥接通知。只有 `/新建 任务内容` 可以不引用。
- `/新建` 不创建新项目目录；Codex 仍要求每个本地任务记录内部工作目录，插件为此使用一个中性专用目录。
- 所有执行命令都不会自动同意权限审批或交互式提问；需要用户确认时会在桌面任务中等待。
- 附件发送会把选定本地文件上传到微信 CDN，默认关闭，需使用者明确开启。

## 更新与卸载

更新时运行 `codex plugin marketplace upgrade codex-wechat-bridge`，重新安装插件，再从新缓存目录运行 `Install-WeChatBridgeService.ps1 -StartNow`。插件状态和微信登录信息会保留。

停止并卸载后台计划任务：

```powershell
pwsh -NoProfile -File .\plugins\codex-wechat-bridge\scripts\Uninstall-WeChatBridgeService.ps1
```

该脚本默认保留本地凭据、队列和日志，避免误删。
