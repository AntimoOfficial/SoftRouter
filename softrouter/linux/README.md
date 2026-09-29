# SoftRouter Linux community test

This is an experimental desktop application for Linux systems with NetworkManager. The release provides an application-only installer; sharing begins only after configuration, confirmation and administrator approval in the app. No actual Linux installation, reboot recovery or downstream network acceptance has been performed. Automated evidence consists of syntax checks and mocked backend tests on the development host.

NetworkManager supplies IPv4 sharing, DHCP, DNS and NAT. There is no SoftRouter background daemon. NetworkManager retains the sharing profile when the GUI closes and is configured to reconnect it after reboot. Upstream loss does not trigger a SoftRouter stop/restart loop. Whether a particular distribution, adapter and upstream recover correctly requires community testing.

The Linux edition does not reproduce the macOS firewall design. NetworkManager shared NAT follows the current default connection, so traffic is not pinned to the selected upstream. Enable refuses a mismatched default route; later inspection reports a mismatch without changing routes. IPv6 is disabled only on the new downstream profile. Sleep, lid behavior, Wi-Fi selection and system-wide IPv6 settings are unchanged.

## Install the app

Use a desktop Linux distribution with Python 3.9 or newer, Tk, NetworkManager, nmcli, iproute2, PolicyKit and the DHCP/DNS dependency required by NetworkManager shared mode. On Debian/Ubuntu these normally correspond to python3, python3-tk, network-manager, iproute2, policykit-1 and dnsmasq-base. A graphical PolicyKit authentication agent must be running.

For Debian/Ubuntu, open the downloaded `.deb` in the system package installer, or install it with dependencies from a terminal in the download directory:

```sh
sudo apt install ./SoftRouter-0.1.0-alpha.5-linux-test_all.deb
```

For the release archive, extract its files, then run:

```sh
sudo /bin/bash install.sh
```

The installer copies application files into /opt/softrouter and adds the desktop launcher and icon. It refuses to overwrite an existing installation. The separate Debian package uses the same installed locations. Installing the app does not create a connection profile, enable forwarding or change power settings.

## Configure and enable

1. Open SoftRouter Linux Test and select Inspect adapters / status. Record the current upstream interface and MAC, then identify a separate physical Ethernet adapter for downstream. Only NetworkManager-managed adapters are supported.
2. Prepare the downstream outside this app: it must be disconnected, have no IPv4 or IPv6 address, and have no active connection. An unplugged Ethernet cable is supported when NetworkManager reports the adapter managed and carrier absent. If a matching saved Ethernet profile exists, it must use DHCP and have autoconnect disabled. Record the original settings before changing them. The app refuses conflicts rather than converting an existing network profile.
3. Copy config.example.json to a private local file. Replace every placeholder with the observed interfaces and MAC addresses, plus an unused RFC1918 IPv4 host address with a /24 prefix. Do not copy device identities from someone else. The selected subnet must not overlap existing addresses or routes.
4. Import the JSON file. Inspect again to see the concrete enable plan or refusal reason. A single IPv4 default route must already use the selected upstream. Existing forwarding, shared profiles and custom routing rules are refused.
5. Select Enable sharing, review the interface and subnet, and approve the PolicyKit prompt. Administrator work uses the root-owned installed backend and treats configuration as JSON data. Without Ethernet carrier, the result is configured and waiting for a cable; it is not active or a successful downstream test. The owned autoconnect profile remains saved, so NetworkManager can attempt activation when the cable is connected. Inspect again to observe the resulting state.
6. Connect the downstream router WAN or test client to the chosen Ethernet port. NetworkManager supplies DHCP and DNS; configure the downstream router WAN for DHCP. Keep its LAN subnet different from the shared subnet. Real downstream access must be verified from a client, with cellular or other fallback paths disabled where applicable.

The GUI reports adapters, MAC addresses, default routes and shared profile UUIDs. Treat these reports as local operational information and redact them before publication. The app does not read Wi-Fi credentials or proxy subscriptions, submit authentication pages, or upload reports.

## Disable and remove

Disable owned sharing deactivates and removes only the UUID recorded under /var/lib/softrouter. The root-only journal stores all persistent profile settings returned by NetworkManager without secret disclosure, excluding the changing connection timestamp. Before modification or deletion, the backend compares these settings, including added authentication, traffic control, Ethernet and proxy groups. An edited or unknown profile is left intact and the recovery journal is retained. Secret values are never requested or stored.

NetworkManager controls the associated forwarding, firewall, DHCP and DNS effects. Successful profile removal does not establish that every global system setting has returned to its earlier value; the app does not flush rules or force forwarding off. Inspect the host state separately before asserting full restoration.

An interrupted creation can leave a journal without enough evidence to prove ownership of the resulting settings. The app deliberately refuses to delete such a profile. Do not remove the journal merely to make the next enable pass; inspect the recorded UUID and actual NetworkManager settings locally and preserve evidence for manual recovery.

After Disable owned sharing succeeds, remove an archive installation with:

```sh
sudo /bin/bash /opt/softrouter/uninstall.sh
```

For a Debian package installation, use `sudo apt remove softrouter`; the standalone uninstaller refuses to remove package-managed files.

The uninstaller refuses to remove the application while an ownership or recovery journal remains. It does not flush firewall rules, delete unrelated profiles, restore a previous DHCP profile or change upstream Wi-Fi. Application updates are not automatic; do not replace an active experimental deployment.

Package removal and upgrade first create a private maintenance marker under /var/lib/softrouter while holding the same lock used by sharing operations. Enable refuses this marker, including from an already open GUI. Removal leaves the marker in place; a completed installation or upgrade checks the installed payload and then clears the recognized marker. These maintenance steps do not change the network.

Interrupted maintenance keeps sharing blocked. Complete the interrupted package installation through the package manager, or complete the archive installation, so its final package-end check can run. If application files are already complete, an administrator can use `sudo /usr/bin/python3 -I /opt/softrouter/backend.py package-end` to check the installed payload and clear a recognized marker. This refuses an outstanding ownership journal or an unknown, symlinked, non-private or malformed marker; it does not delete unclear recovery data. Do not remove the marker manually to bypass the check.

## Offline checks

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 -m py_compile app.py backend.py
/bin/bash -n install.sh uninstall.sh
```

Tests use synthetic interfaces and an in-memory NetworkManager double. They do not invoke nmcli, alter routes or create real connection profiles. Successful tests establish parser and lifecycle behavior, not Linux or hardware compatibility.

The sharing model follows the [NetworkManager IPv4 settings reference](https://www.networkmanager.dev/docs/api/latest/settings-ipv4.html). Interface ownership and failure handling are deliberately stricter than NetworkManager itself.
