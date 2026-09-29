# Contributing

The project provides an experimental macOS IPv4 gateway and separate Windows ICS / Linux NetworkManager community test editions. Changes should state the concrete failure, expected behavior, and evidence used to validate the fix.

## Local checks

```sh
/bin/bash softrouter/tests/run.sh
python3 softrouter/tools/check-publication.py
```

The Bash tests use temporary files and command doubles. They do not install a gateway or change live networking. The macOS gateway does not require Python; the Linux application uses Python 3.9 or newer.

Linux backend mocks run with `python3 -m unittest discover -s softrouter/linux/tests -v`. On Windows, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File softrouter/windows/tests/Offline.Tests.ps1` using Windows PowerShell 5.1. CI runs these checks without enabling sharing. Build Windows/Linux release files from an audited commit with `python3 softrouter/tools/build-portable.py --head`.

Use a separate, recoverable environment for installation, DHCP reacquisition, upstream disconnection, reboot, USB removal and sleep tests. Do not perform disruptive tests on a working gateway without authorization. Record hardware, operating-system version, backend, tested steps, duration and the exact commit. Do not attach raw packet captures, subscriptions, credentials or personal configuration.

Public additions must be listed in PUBLISH_FILES.txt. Before committing, validate the actual Git index with `python3 softrouter/tools/check-publication.py --staged`. CI checks the same boundary, but cannot retract material already pushed; local review is required.

Tests and docs should distinguish simulated regressions from real client observations. A running daemon or successful host curl alone does not prove downstream forwarding works. Backend differences are documented in the platform guide; no edition provides automatic router management or automatic updates.
