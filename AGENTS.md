# Repository instructions

Read README.md, air-gateway/docs/ai-setup.md, and air-gateway/docs/compatibility.md before deploying. All agent tools must obey their own permissions and credential handling requirements.

## Scope

- Public code lives under air-gateway/. PUBLISH_FILES.txt is the exact release allowlist.
- The workspace may contain ignored private operational material. Do not stage, publish, move, delete, or quote that material merely to prepare a release. Use only explicitly scoped private diagnostics when the user requests local troubleshooting.
- Preparing the repository does not authorize installing it on a working gateway. Distinguish source changes, offline tests, and live deployment.
- Do not infer that planned commands exist. Use the commands documented in the current installation guide; roadmap interfaces are not implemented.

## Network operations

- Discover interface, network service UUID, MAC, routes and DNS from the actual host. Never copy example device identities into a live configuration.
- Check for an existing gateway before attempting installation. The current installer supports fresh installation only. Do not install alongside or overwrite a working gateway.
- Complete read-only discovery and a concrete change/recovery plan before requesting any necessary administrator action. Keep already authorized work moving without repeated confirmation.
- Keep credentials local. Do not request passwords, private keys, proxy subscriptions or complete system network preferences in chat or issues.
- Never flush global PF rules, delete an unexplained recovery lock, disable upstream Wi-Fi, or renew DHCP solely to make a preflight pass.
- Upstream loss is an observation, not a request to stop or restart the gateway. Do not confuse service readiness with downstream internet access.
- Do not enable system-wide sleep suppression by default. Power changes require a scoped plan and real downstream verification.
- A successful HTTP status can still be an application error. Check the intended public page and obtain downstream/browser evidence when relevant. Do not submit authentication forms without user authorization.

## Development and publication

- Use /bin/bash compatibility suitable for the macOS-provided Bash 3.2.
- Preserve DHCP local delivery and no-transit protection in normal and cleanup protection rules.
- Configuration is data, never sourced or evaluated as shell code.
- Run /bin/bash air-gateway/tests/run.sh after relevant changes. Tests must not alter live PF, routes, DHCP, network services or power settings.
- Add intentional new public files to PUBLISH_FILES.txt. Run python3 air-gateway/tools/check-publication.py --staged before committing and --head before packaging.
- Do not use git add -f for ignored operational files. A failed publication check must be investigated rather than bypassed.
- Record whether evidence is simulated, syntax-only, live on a dedicated deployment, or live on this generic package. Never promote untested behavior to a compatibility claim.
