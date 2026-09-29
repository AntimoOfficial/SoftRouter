# SoftRouter

Share a computer's Wi-Fi connection with a regular Ethernet router, with setup instructions designed for your local AI assistant.

[Downloads](https://github.com/AntimoOfficial/SoftRouter/releases/latest) · [中文](../../README.md) · [Test report](https://github.com/AntimoOfficial/SoftRouter/issues/new?template=platform-test.md)

```text
Authenticated Wi-Fi → computer → Ethernet → router WAN → LAN / Wi-Fi clients
```

The operating system handles campus or enterprise authentication. SoftRouter helps configure sharing, preserves recovery information, and explains the limits of the evidence it collects. It does not provide VPN servers or replace network authentication.

| Platform | Download | Backend and evidence |
|---|---|---|
| macOS 14+ | Universal `.pkg` | PF and launchd; a dedicated deployment has real downstream evidence |
| Windows 10/11 | `windows-test.zip`, extract and double-click `Install.cmd` | Native ICS; first community test edition, no real network validation |
| Linux desktop | `linux-test_all.deb` or `linux-test.tar.gz` | NetworkManager sharing; first community test edition, no real network validation |

Packages install the application first. Sharing requires a separate, explicit operation. Installers are unsigned. Existing gateways are not automatically migrated. Details and backend differences: [platform guide](platforms.md), [Windows](../windows/README.md), [Linux](../linux/README.md), [macOS](desktop-installer.md).

## Hand the repository to your AI

> Read the repository README, AGENTS.md, platform guide, and instructions for this operating system. Inspect my interfaces and existing sharing setup without changing anything. Identify the authenticated upstream and an unused Ethernet interface, prepare the exact configuration and recovery plan, and use the provided installer. Ask me to connect cables or enter administrator credentials locally when required. Verify access from a real downstream device and distinguish success, failure, and untested behavior.

An AI needs local tools to perform setup; a chat-only assistant can explain the steps. Credentials stay on your computer. Network inspection and diagnostic reports stay local unless you explicitly share redacted excerpts.

## Evidence before claims

Process lifetime is not network uptime. An HTTP response is not proof that the intended page works. A host-side request is not a downstream test. A one-off lid test does not establish support across power sources or hardware.

The macOS application includes local diagnostics and power-policy interpretation. Windows and Linux editions deliberately use their operating system's sharing backend rather than claiming the same packet-filter behavior. See [compatibility](compatibility.md).

## Contribute

The most useful early contribution is a reproducible platform test: OS and adapter versions, app installation, real downstream access, and restoration after disabling sharing. Never post credentials or complete network preferences. [MIT license](../../LICENSE).
