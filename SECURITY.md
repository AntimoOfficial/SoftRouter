# Security

This project modifies privileged macOS networking and is an experimental preview. Supported behavior and test limitations are listed in air-gateway/docs/compatibility.md.

Do not put credentials, private keys, router tokens, subscriptions, raw network preferences or private recovery directories in public issues. If the repository enables GitHub private vulnerability reporting, use its Security tab. Otherwise, ask the maintainer for a private reporting channel without publishing exploit details or secrets.

Publication checks provide a file allowlist and common secret-pattern checks; they are not a proof that every possible secret is absent. Review all added files before pushing. Local operational data is excluded by default, and release archives are built from a verified commit.

The installed daemon requires root-owned code and data, parses configuration without shell evaluation, tracks owned PF resources, and refuses unexplained ownership takeover. These safeguards do not guarantee uninterrupted campus authentication, hardware availability or recovery from kernel failures.
