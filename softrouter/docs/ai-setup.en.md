# AI deployment guide for SoftRouter on macOS

SoftRouter turns an awake Mac into an IPv4 gateway between authenticated upstream Wi-Fi and a downstream router. macOS manages Wi-Fi association, enterprise or campus 802.1X authentication, and credentials; SoftRouter provides PF NAT and launchd service management. Starting the service does not establish authentication before login.

```text
Upstream Wi-Fi -> Mac -> separate Ethernet adapter -> router WAN -> LAN / Wi-Fi clients
```

This guide covers the macOS PF backend. Read the repository [README](../../README.md), [AGENTS.md](../../AGENTS.md), [macOS installation reference](../README.md), and [compatibility record](compatibility.md) before deployment. Windows uses ICS and Linux uses NetworkManager: follow [platform selection](platforms.md) and the corresponding platform README, never the PF or launchd commands below.

The project is experimental. A dedicated Apple M1 deployment on macOS 14.8.5 with USB Ethernet and a Xiaomi AX3000T has recorded successful downstream access; that does not validate the generic package, other hardware, unattended recovery, or overnight operation. Offline tests and package builds are distinct from installation and network acceptance.

## 1. Discover the target host without changing its network

An AI needs local terminal access to act; a chat-only assistant can explain steps. The user may need to handle cables, authenticate upstream, and approve local administrator prompts. Keep passwords, proxy subscriptions, full network preferences, and unredacted discovery output on the host.

First check for an existing SoftRouter or Air Gateway deployment, Internet Sharing, another gateway, VPN software, or a PF manager. Do not overwrite a working deployment or treat its migration as part of preparing this repository. If privileged PF evidence cannot be read, record it as unknown rather than assuming PF is disabled or empty.

These existing commands are read-only:

```sh
sw_vers
uname -m
/usr/sbin/networksetup -listallhardwareports
/usr/sbin/networksetup -listnetworkserviceorder
/sbin/route -n get default
/usr/sbin/scutil --dns
/usr/sbin/sysctl net.inet.ip.forwarding net.inet6.ip6.forwarding
/usr/bin/pmset -g
/usr/bin/pmset -g custom
```

Match each physical adapter to its interface, network service, service UUID, and MAC using the installation reference. Do not copy example identities or guess among multiple adapters. The downstream interface must be independent and unused, not the default route or a remote-management path. Do not upload the complete system preferences file.

Identify the intended upstream Wi-Fi and every saved SSID of the downstream router without switching networks. An interface name does not identify an SSID: the same Wi-Fi interface can join the downstream network while the gateway still reports RUNNING.

## 2. Prepare local configuration and a recovery plan

Generate a private `gateway.conf` from `gateway.conf.example` using the seven fields and validation rules in the installation reference. Configuration is data, never shell code. Keep it out of Git. Choose a private `/24` that does not overlap the upstream, existing routes, or the router LAN.

The keys are `UPSTREAM_INTERFACE`, `DOWNSTREAM_INTERFACE`, `DOWNSTREAM_SERVICE`, `DOWNSTREAM_SERVICE_UUID`, `DOWNSTREAM_MAC`, `GATEWAY_ADDRESS`, and `CLIENT_ADDRESS`. Populate all seven from the verified host and address plan, not the example's device identities.

Record the verified interfaces and service identities, original downstream service settings, Mac downstream address, router WAN address, mask, gateway, actual upstream DNS, required cable changes, and the exact restoration steps. Use [DNS and proxy guidance](dns-and-proxy.md); do not substitute fixed public or institution-specific DNS addresses.

On the gateway Mac, open System Settings → Wi-Fi and inspect the known networks or their details:

1. Record the original Auto-Join settings; keep Auto-Join enabled for the intended upstream.
2. Disable Auto-Join for each saved downstream-router SSID. If a network is not saved, record that; do not join it to perform this check.
3. Reopen the settings to verify the saved values, then confirm that the upstream and default route have not changed.

Auto-Join reduces accidental reconnection to the selected downstream Wi-Fi. It does not block manual joins, verify 802.1X recovery, or make SSID an enforcement boundary: PF restricts the egress interface, not the network name. Preserve credentials; do not forget networks, edit private preference plists, disable upstream Wi-Fi, or add a switching daemon. Restore only the recorded toggles when rolling back.

From the repository root, run the documented offline checks:

```sh
/bin/bash softrouter/tests/run.sh
/bin/bash softrouter/install.sh --check
```

Passing these checks is not proof of target compatibility or live forwarding. Present a concrete change and recovery plan before any necessary administrator action; do not repeatedly request approval for steps already authorized.

## 3. Prepare the independent interface and install

Keep the upstream connected and the USB adapter attached to the Mac, but unplug its downstream Ethernet cable. This prevents a router DHCP server from taking over the Mac's default route during preparation. Record the original service enablement, IPv4/IPv6 settings, and routes before changing them.

Use the installation reference to prepare only the verified idle downstream service: Disabled, DHCP, automatic IPv6, with its interface DOWN and without IPv4/IPv6 addresses. The installer does not convert an interface with another purpose. If the baseline differs, resolve its ownership and plan the change rather than applying example commands blindly.

The [desktop installer](desktop-installer.md) offers an application-only package: installing the app does not enable sharing. Importing configuration also leaves the network unchanged. The gateway is enabled only through the explicit install action and local system authorization. The preview is not Developer ID signed or notarized; respect the user's trust decision and organizational security policy.

For the documented source installation, run from the repository root and replace the configuration placeholder with its real absolute path:

```sh
sudo /bin/bash softrouter/install.sh --config /absolute/path/gateway.conf
/Library/SoftRouter/gatewayctl status
```

Administrator authentication stays in the local system prompt. If the AI tool lacks the required permission, the user performs that specific local step; never ask for the password or bypass the tool's restrictions through terminal UI control.

The installer supports fresh installation only. Existing installations, occupied PF resources, unexplained recovery state, or failed preflight stop this installation path. Inspect the actual error. Never flush global PF rules, delete a recovery lock, renew DHCP, or disable the upstream merely to make preflight pass. Updating the GUI does not upgrade an installed gateway; check its existing help before using newer diagnostic options.

## 4. Connect and configure the router

Use the [generic router guide](routers/generic.md) or a verified model guide. Preserve a LAN management path and identify the actual WAN port. Give the user a concrete parameter table: WAN = `CLIENT_ADDRESS`, mask = `255.255.255.0`, gateway = `GATEWAY_ADDRESS`, and reachable upstream DNS; keep the router LAN on a different subnet.

After the gateway reports RUNNING, attach the downstream cable to that WAN port. Router settings require an authorized local management session or user action. Do not assume a Xiaomi port layout or private API applies to another model. SoftRouter does not import proxy subscriptions or implement campus authentication.

## 5. Verify service, upstream, and downstream separately

Record three independent results: service configuration established, upstream usable, and a real downstream client usable. RUNNING proves only the first.

- Confirm the Mac still uses the intended upstream and default route; reopen Wi-Fi settings to verify Auto-Join. Settings verification alone is not a disconnection or recovery test.
- Confirm a client is attached to the downstream router. Temporarily disable cellular data and other alternate paths on the test device so success cannot come from another connection.
- Test DNS and direct HTTPS to the user's intended public sites; verify any enabled proxy path separately. An HTTP 200 or a successful Mac request does not prove that the intended page or a downstream client works.
- For a campus network, include both an ordinary external site and an intended campus site. Allow old DNS caches to expire after a DNS change; a timeout alone does not identify the forwarding service as its cause.
- Without access to a downstream client, record downstream acceptance as unverified rather than declaring completion.

Keep the gateway running during a temporary upstream outage; restored upstream access may permit new connections while applications retry old ones. Restarts, DHCP renewal, USB removal, reboot, sleep, and lid closure are disruptive tests: run them only in an authorized recoverable window and record the exact scope under [testing guidance](testing.md). Do not enable system-wide sleep suppression by default.

## 6. Record results and recover within the ownership boundary

Keep the version, configuration basis, original settings, acceptance results, and untested items in a private local record. For recent reports or troubleshooting, use the existing [diagnostic workflow](diagnostics.md); it does not install or repair networking. Redact shared evidence using [privacy guidance](privacy.md).

The existing macOS controls are:

```sh
sudo /Library/SoftRouter/gatewayctl stop
sudo /Library/SoftRouter/gatewayctl start
sudo /Library/SoftRouter/gatewayctl uninstall
```

Normal stop cleans only resources owned by this gateway. ATTENTION or incomplete cleanup requires inspection; do not assume uninstall restored everything. Uninstall retains logs and leaves the prepared downstream service disabled. Removing the GUI app does not stop the launchd gateway. Restore manual preparation changes from the original record, and do not blindly re-enable DHCP while the router cable remains connected.
