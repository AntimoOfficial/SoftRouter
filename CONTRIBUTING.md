# Contributing

The project is an experimental macOS IPv4 gateway. Changes should state the concrete failure, expected behavior, and evidence used to validate the fix.

## Local checks

```sh
/bin/bash softrouter/tests/run.sh
python3 softrouter/tools/check-publication.py
```

The Bash tests use temporary files and command doubles. They do not install a gateway or change live networking. Python 3 is required only for publication checks, not for the installed gateway.

Use a separate, recoverable environment for installation, DHCP reacquisition, upstream disconnection, reboot, USB removal and sleep tests. Do not perform disruptive tests on a working gateway without authorization. Record hardware, macOS version, tested steps, duration and the exact commit. Do not attach raw packet captures, subscriptions, credentials or personal configuration.

Public additions must be listed in PUBLISH_FILES.txt. Before committing, validate the actual Git index with `python3 softrouter/tools/check-publication.py --staged`. CI checks the same boundary, but cannot retract material already pushed; local review is required.

Tests and docs should distinguish simulated regressions from real client observations. A running daemon or successful host curl alone does not prove downstream forwarding works. IPv6 forwarding, automatic router APIs and automatic updates are outside the current implementation.
