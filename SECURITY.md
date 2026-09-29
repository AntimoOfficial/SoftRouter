# Security

This project modifies privileged networking on macOS and provides experimental Windows ICS / Linux NetworkManager adapters. Supported behavior and test limitations are listed in softrouter/docs/compatibility.md and the platform READMEs.

Do not put credentials, private keys, router tokens, subscriptions, raw network preferences or private recovery directories in public issues. If the repository enables GitHub private vulnerability reporting, use its Security tab. Otherwise, ask the maintainer for a private reporting channel without publishing exploit details or secrets.

Publication checks provide a file allowlist and common secret-pattern checks; they are not a proof that every possible secret is absent. Review all added files before pushing. Local operational data is excluded by default, and release archives are built from a verified commit.

The macOS daemon requires root-owned code and data, parses configuration without shell evaluation, tracks owned PF resources, and refuses unexplained ownership takeover. Windows and Linux instead track their native sharing resources and administrator-protected recovery records; they do not reproduce the macOS packet-filter guarantees. These safeguards do not guarantee uninterrupted campus authentication, hardware availability or recovery from kernel failures. Packages are currently unsigned by a verified publisher; checksum and internal integrity checks do not authenticate an untrusted download.
