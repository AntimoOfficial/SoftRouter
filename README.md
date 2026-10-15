# SoftRouter

<img src='softrouter/macos/assets/SoftRouterIcon.png' width='88' alt='SoftRouter icon'>

**Share a computer’s Wi-Fi connection with an Ethernet router. Let your local AI assistant guide the setup.**

[Download](https://github.com/AntimoOfficial/SoftRouter/releases/latest) · [简体中文](README.zh-CN.md) · [AI setup guide](softrouter/docs/ai-setup.en.md) · [Report a problem](https://github.com/AntimoOfficial/SoftRouter/issues/new/choose)

SoftRouter is an experimental **Wi-Fi-to-Ethernet software router**. It turns a computer with an authenticated Wi-Fi connection and a separate Ethernet adapter into an IPv4 gateway for a regular router. Devices connect through that router’s existing LAN or Wi-Fi.

The macOS backend uses **PF, IPv4 NAT and launchd**. Separate **Windows Internet Connection Sharing (ICS)** and **Linux NetworkManager** editions are available for community testing. Deployment guides and local Markdown/JSON diagnostics help humans and AI assistants inspect the same evidence.

```text
Campus / enterprise Wi-Fi (including OS-managed 802.1X authentication)
    → computer running SoftRouter → Ethernet → router WAN → LAN / Wi-Fi devices
```

## When to use it

- Share campus or enterprise Wi-Fi with devices behind a wired router, after the computer has authenticated through its operating system.
- Use a Mac as a Wi-Fi-to-Ethernet IPv4 gateway with an ordinary router and USB Ethernet adapter.
- Let an AI assistant with local tools inspect interfaces, prepare a concrete configuration and recovery plan, and follow documented installation steps.
- Collect local network diagnostics for troubleshooting DNS, Wi-Fi authentication events, DHCP, link state and power conditions.

The operating system handles Wi-Fi authentication and credentials. SoftRouter routes traffic; it does not implement a campus login protocol or provide a VPN service.

## Download and platform status

Current release: **0.1.0-alpha.6**, an experimental release. [Release notes and downloads](https://github.com/AntimoOfficial/SoftRouter/releases/latest).

| Platform | Download and entry point | Backend and validation |
|---|---|---|
| macOS 14+, Apple Silicon / Intel | Universal `.pkg`; install and open SoftRouter | PF/NAT and launchd. A dedicated deployment has real downstream evidence; the generic installer still needs end-to-end validation. |
| Windows 10/11 | `windows-test.zip`; extract and run `Install.cmd` | Native ICS community test edition; offline tests only, no real downstream validation yet. |
| Linux desktop | `linux-test_all.deb` or `linux-test.tar.gz` | NetworkManager shared connection community test edition; offline tests only, no real downstream validation yet. |

The packages install the application first. Enabling network sharing is a separate operation. The macOS app carries an ad-hoc integrity signature; its installer package is unsigned, with no Developer ID signing or notarization. Windows/Linux packages also lack publisher signing. Existing gateways are preserved, with no automatic migration or update.

Platform-specific instructions: [macOS desktop installer](softrouter/docs/desktop-installer.md), [Windows ICS](softrouter/windows/README.md), [Linux NetworkManager](softrouter/linux/README.md). The Windows and Linux READMEs are in English. Some macOS and operational manuals remain in Chinese; the [English AI setup guide](softrouter/docs/ai-setup.en.md) explains the macOS workflow.

## Set up with your local AI assistant

Give the repository URL and this prompt to an assistant that can use tools on your computer:

> Read README.md, AGENTS.md, the English AI setup guide and the instructions for my operating system. Inspect the current network, interfaces and existing gateways without changing them. Identify the authenticated Wi-Fi upstream and an unused Ethernet interface. Prepare the exact configuration and recovery plan, then use the documented installer only if this is a fresh installation. Keep credentials local. Verify internet access from a real downstream device, and distinguish successful, failed and untested steps.

A chat-only assistant can explain the procedure; local tools are needed to perform it. You may need to connect cables and enter administrator or network credentials directly on your computer.

Start here: [English AI setup guide](softrouter/docs/ai-setup.en.md) · [中文部署手册](softrouter/docs/ai-setup.md) · [Compatibility and test evidence](softrouter/docs/compatibility.md).

## Local diagnostics for people and AI

In the macOS app, choose 「生成诊断报告」, or run from the repository:

```sh
/bin/bash softrouter/diagnose.sh --days 3
```

The report directory contains `report.md` for people and schema 1 `report.json` for tools. Reports stay local. This command requires no administrator privileges and does not change network settings; website requests require explicit URL options.

Diagnostics distinguish current service evidence, historical Wi-Fi/DHCP events, collection gaps and unverified downstream access. A running process is not proof of continuous internet access. See the [diagnostic workflow](softrouter/docs/diagnostics.md) and [SoftRouter health skill](softrouter/skills/softrouter-health/SKILL.md).

## Common questions

### Is this a Wi-Fi-to-Ethernet bridge?

SoftRouter implements routed IPv4 sharing with NAT, rather than a transparent Layer 2 bridge. The Ethernet link connects the computer to the downstream router’s WAN port.

### Can it share 802.1X campus Wi-Fi?

The computer must first connect and authenticate using the operating system. SoftRouter then shares that upstream connection. Authentication recovery and campus DNS behavior depend on the actual network; validate the intended sites from a downstream device.

### Does sharing automatically use my VPN or system proxy?

Traffic follows the selected backend and routing configuration. A host application’s HTTP/SOCKS proxy does not automatically apply to forwarded clients. See [DNS and proxy behavior](softrouter/docs/dns-and-proxy.md).

### Are all platforms and routers verified?

No. Dedicated macOS deployment evidence, generic-package tests and Windows/Linux offline tests have different scopes. Exact hardware, recovery and power limitations are documented in [compatibility](softrouter/docs/compatibility.md). Features marked as planned or unreleased are not part of the current download.

## Documentation and contributions

- [Configuration and gateway commands](softrouter/README.md)
- [Platform differences](softrouter/docs/platforms.md)
- [Troubleshooting](softrouter/docs/troubleshooting.md)
- [Power and lid behavior](softrouter/docs/power-and-lid.md)
- [Roadmap](softrouter/docs/roadmap.md)
- [Contributing](CONTRIBUTING.md) and [platform test reports](https://github.com/AntimoOfficial/SoftRouter/issues/new?template=platform-test.md)
- [Security reporting](SECURITY.md) and [privacy](softrouter/docs/privacy.md)

Reproducible reports with operating-system, adapter and real downstream test results are useful at this experimental stage. Keep credentials and private operational data out of public issues. Public release inputs are explicitly listed in `PUBLISH_FILES.txt`.

[MIT license](LICENSE).
