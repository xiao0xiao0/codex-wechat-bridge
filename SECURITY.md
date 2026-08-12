# Security policy

## Supported version

Security fixes are applied to the latest published version only.

## Data boundaries

- Runtime credentials, WeChat identifiers, queues, logs and routing state are created only under `%LOCALAPPDATA%\CodexWeChatBridge` unless the user overrides `CODEX_WECHAT_BRIDGE_HOME`.
- Credentials are encrypted with Windows DPAPI for the current Windows user.
- These runtime files must never be committed to the repository or included in support bundles.
- Completion attachments are disabled by default. Enabling them uploads selected local files to Tencent's WeChat CDN.

## Reporting a vulnerability

Do not open a public issue containing tokens, QR codes, user IDs, message payloads, local paths or logs with private data. Use GitHub's private vulnerability reporting for this repository. If that feature is unavailable, open a public issue containing only a request for a private contact channel.

When reporting, include the plugin version, Windows version and a redacted reproduction. Revoke or re-bind the WeChat bot immediately if a credential may have been exposed.
