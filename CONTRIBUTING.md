# Contributing

Contributions are welcome for Windows compatibility, delivery reliability, documentation and tests.

1. Fork the repository and create a focused branch.
2. Do not commit `%LOCALAPPDATA%\CodexWeChatBridge`, QR codes, tokens, user IDs, logs, rollout files or machine-specific paths.
3. Run `pwsh -NoProfile -File .\tests\Validate-PublicRelease.ps1`.
4. Describe user-visible behavior and validation in the pull request.

Live WeChat tests must use the contributor's own account and must never be enabled in CI.
