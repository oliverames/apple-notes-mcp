# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x.x   | :white_check_mark: |
| < 2.0   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it by emailing:

**rob@superiortech.io**

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

You will receive a response within 48 hours acknowledging receipt. Security issues will be prioritized and addressed as quickly as possible.

## Security Considerations

This MCP server:
- Runs locally on your machine
- Uses AppleScript to interact with Notes.app
- Does not transmit data to external servers
- Does not store credentials or passwords
- Cannot access password-protected notes
- Listens on no network port, except the optional paragraph anchor resolver
  (`apple-notes-mcp anchors serve`), which you start yourself. It binds
  127.0.0.1 (or, with `--tailnet`, your Tailscale address), requires a token
  on every request, checks the `Host` header, and stops on Ctrl-C. See
  [Paragraph anchor resolver](README.md#paragraph-anchor-resolver-opt-in)

The server requires macOS automation permissions to function. These permissions are managed by macOS and can be revoked at any time in System Settings > Privacy & Security > Automation.
