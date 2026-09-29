# SoftRouter for Windows - community test edition

This is a separate Windows implementation using the operating system Internet Connection Sharing (ICS) backend. It is source distributed and unsigned. It has not been tested on a real gateway or with a downstream client. Parser and mocked workflow checks do not establish network compatibility.

Target: 64-bit Windows 10 build 19041 or later and Windows 11, Windows PowerShell 5.1, administrator access, one connected physical upstream adapter and a separate physical Ethernet downstream adapter. Windows Server, virtual adapters, existing sharing/NAT/bridges, mobile hotspot and RRAS are excluded. Required networking cmdlets or services that cannot be inspected cause refusal, including on unsupported editions or managed machines.

## Install and open

1. Extract the entire Windows release ZIP to a local directory. Keep its files together. Read this document before running an unsigned installer.
2. Double-click `Install.cmd` and approve the Windows administrator prompt. The installer copies the application to `%ProgramFiles%\SoftRouter` and creates a Start Menu shortcut. It installs no driver or background task and performs no network or power operation.
3. Open **SoftRouter** from the Start Menu, or double-click the installed `Start.cmd`.

The initial installer is the trust boundary: there is no Authenticode signature. It refuses an existing installation or state directory, installs under administrator-controlled ACLs, compares source and destination hashes, and records an installed payload manifest. Each installed entry point validates this payload. The manifest detects subsequent corruption; it does not authenticate a downloaded release or resist an administrator replacing the application. Process-scoped execution-policy bypass does not change machine execution policy; organizational policy may still block execution.

## Review and enable

1. Inspect the actual adapters. Keep the upstream connected. Choose the upstream and dedicated Ethernet downstream explicitly by GUID; names and MAC addresses are also inspected. No example GUID is usable.
2. Before activating, unplug only the downstream Ethernet cable. That adapter must already use DHCP and automatic DNS, with no static IPv4 addresses, static routes or default route. If it currently serves another purpose, first record its settings and prepare a separate recovery plan. The application does not convert an occupied interface to make preflight pass.
3. Select **Review and enable**, review both adapter identities and the changes, then approve UAC. The elevated controller repeats discovery and preflight. Existing ICS, port mappings on the selected connections, NetNat, active Mobile Hotspot/RRAS and bridge bindings cause refusal; those resources are never removed or disabled.
4. After the result reports `ACTIVE`, read the actual downstream IPv4 address in the result. Windows chooses the ICS subnet; this program does not hardcode or promise `192.168.137.0/24`.
5. Set the router **WAN to DHCP/automatic IP and DNS**, connect the selected Ethernet adapter to that WAN port, and retain the router LAN management path. Router LAN and the reported ICS subnet must differ. Ensure the chosen ICS subnet does not overlap upstream, VPN or other routes; subnet overlap remains a manual acceptance check in this test edition.
6. Validate on a real router client, with cellular data and other fallback routes disabled. Check the intended public page in a browser. `ACTIVE` only confirms observed sharing roles and an assigned private IPv4 address; it is never a connectivity verdict.

Closing the application does not disable ICS. Windows controls its service behavior. No automatic reconnect, watchdog, startup reapplication, sleep suppression or proxy integration is installed. Persistence across a restart, source changes, unplugging, sleep and closed-lid use remains unverified. Authentication belongs to Windows and the user. No credentials are requested or stored.

## Disable, recovery and uninstall

**Disable / recover** requests UAC and interrupts clients using this sharing instance. It validates both adapter identities, sharing roles, port mappings and recorded downstream settings. It disables only acknowledged sharing on the selected pair, then restores the eligible DHCP/automatic-DNS baseline when the current state still matches the owned state. It never flushes other NATs, disables upstream Wi-Fi, or disables the Windows firewall. ICS-managed firewall or service policy changes are not reverted by this edition.

Before each mutation, a journal is saved under `%ProgramData%\SoftRouter`, readable and writable only by Administrators and SYSTEM. Failed activation keeps this journal. An acknowledged public-only partial activation can be recovered with **Disable / recover**. A crash between a COM mutation and its acknowledgement, altered adapter settings, new port mappings, or an unknown shared connection causes `ATTENTION`; the tool refuses to infer ownership. Do not delete `state.json` to force a new activation. An administrator can inspect its exact GUIDs and phases and compare them with Windows adapter sharing properties. Recovery from ambiguous ownership requires that local review; it is not an automatic takeover feature.

Use the installed `Uninstall.cmd` only after recovery has completed. It refuses active/incomplete state and removes the application and its own shortcut; protected recovery history remains. An existing state directory intentionally blocks fresh installation, so reinstalling after uninstall requires an administrator to account for and archive that history first. No automatic upgrade or migration is implemented.

## Controller and JSON configuration

From Windows PowerShell 5.1, the installed controller supports these commands. `Inspect` and `Status` are read-only; protected state may require an elevated terminal. `Plan` performs preflight without mutation. `Enable` and `Disable` require administrator rights and an explicit console confirmation; the GUI supplies approval after its review dialog.

```powershell
& $env:ProgramFiles\SoftRouter\Controller.ps1 -Action Inspect
& $env:ProgramFiles\SoftRouter\Controller.ps1 -Action Status
& $env:ProgramFiles\SoftRouter\Controller.ps1 -Action Plan -ConfigPath C:\Local\gateway.json
& $env:ProgramFiles\SoftRouter\Controller.ps1 -Action Enable -ConfigPath C:\Local\gateway.json
& $env:ProgramFiles\SoftRouter\Controller.ps1 -Action Disable
```

Copy `gateway.example.json` and replace both zero GUIDs with discovered values. It contains exactly `schemaVersion`, `upstreamGuid` and `downstreamGuid`. Duplicate/unknown fields, noncanonical or equal GUIDs, and executable expressions are rejected. JSON is parsed as data and is never dot-sourced or evaluated. A configuration file may be user writable because only these validated scalar values cross into privileged operations. State and executable payloads are administrator protected.

## Offline checks

Run from the unpacked source tree on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Offline.Tests.ps1
```

The test parses every PowerShell source file, validates strict JSON and physical adapter selection, checks rejection of existing and drifted ownership, and executes enable/partial-failure/recovery workflows with all host and network dependencies replaced. It does not call ICS, change adapter settings, query real routes, alter services, change power settings, install the application, exercise UAC, or prove actual traffic forwarding.

## Backend boundaries

Microsoft documents that enabling public ICS automatically disables a previous public sharing connection. Preflight and immediate rechecks therefore reject any existing instance. ICS has no transaction/ownership token for this application: a concurrent administrator can still race the checks, and recreating identical settings cannot be distinguished from unchanged ownership. Do not operate Windows sharing settings or another gateway tool concurrently. The application serializes its own mutating operations.

Native ICS chooses NAT, DHCP, DNS forwarding, IPv6 and firewall behavior. This edition does not reproduce the macOS PF egress isolation or DHCP no-transit rules, enforce an SSID, guarantee IPv6 isolation, or expose custom subnets and port mappings. It is not a drop-in implementation of the macOS security guarantees. These limitations and untested live behavior are part of this test release.

Primary references: [ICS manager](https://learn.microsoft.com/en-us/windows/win32/api/netcon/nn-netcon-inetsharingmanager), [enable sharing and replacement behavior](https://learn.microsoft.com/en-us/windows/win32/api/netcon/nf-netcon-inetsharingconfiguration-enablesharing), [disable sharing and retained firewall behavior](https://learn.microsoft.com/en-us/windows/win32/api/netcon/nf-netcon-inetsharingconfiguration-disablesharing), [sharing role constants](https://learn.microsoft.com/en-us/windows/win32/api/netcon/ne-netcon-sharingconnectiontype), [NetNat inventory](https://learn.microsoft.com/en-us/powershell/module/netnat/get-netnat).
