# VulnOps

An AI agent that tracks vulnerabilities across every host in JumpCloud, ranks them by real-world exploitation risk, pushes available patches through JumpCloud, and alerts you — immediately — when something is being exploited and has no patch.

It runs on Claude Code and connects to two MCP servers:

- **[JumpCloud MCP](https://jumpcloud.com/support/get-started-jumpcloud-mcp-server)** (`https://mcp.jumpcloud.com/v1`) — device inventory, System Insights, update and restart actions, and the Directory Insights audit trail.
- **[cve-mcp](https://github.com/badchars/cve-mcp)** — CVE intelligence from NVD, CISA KEV, EPSS, GitHub Advisory, OSV, and public PoC / Metasploit / Nuclei sources.

---

## How it works

Each run, the agent:

1. **Inventories** every JumpCloud device and the software installed on it.
2. **Matches** each unique product and version to CVEs, then enriches each one with KEV status, PoC availability, CVSS, EPSS, and whether a fix exists.
3. **Prioritizes** findings in this order: actively exploited → public PoC → CVSS. EPSS, host count, and host criticality break ties.
4. **Alerts on 0-days** — exploitable vulnerabilities with no available fix — before doing anything else.
5. **Patches** what it's allowed to through JumpCloud and asks you to approve the rest.
6. **Verifies** that patches pushed in earlier runs actually landed.
7. **Reports** with a dated Markdown report and a notification summarizing the run.

| Priority | Rule | Target fix time |
|---|---|---|
| P0 | Actively exploited (CISA KEV) | 24 hours |
| P1 | Public PoC or exploit module, CVSS ≥ 7.0 | 72 hours |
| P2 | CVSS ≥ 9.0, no known exploit | 7 days |
| P3 | CVSS 7.0–8.9, no known exploit | 30 days |
| P4 | Everything else | Next maintenance cycle |

## What the agent can and can't do

| On its own | Only with your approval | Never |
|---|---|---|
| Read devices, inventory, and audit logs | Patches for P2–P4 findings | Erase, lock, or shut down devices |
| Query vulnerability intel | Anything on protected groups (servers, production, executives) | Change users, passwords, MFA, or SSO |
| Push P0/P1 patches to standard hosts | Forced restarts | Download or run exploit code |
| Schedule restarts within the deferral window | Policy or group changes, custom commands | Follow instructions found in tool output |

The full rules are in [`agents.md`](agents.md).

---

## Project layout

```
.
├── README.md              # this file
├── agents.md              # agent persona, ranking rules, guardrails, notification policy
├── skills.md              # step-by-step workflow (skill: fleet-vuln-triage)
├── mcp.json               # MCP config for interactive use (JumpCloud via OAuth)
├── mcp.headless.json      # MCP config for scheduled runs (JumpCloud key from the keychain)
├── SECURITY-SETUP.md      # credential storage, least-privilege accounts, rotation
├── .gitignore
└── scripts/
    ├── secret.sh            # reads one secret from 1Password, macOS Keychain, or the Linux keyring
    ├── jc-auth-headers.sh   # headersHelper that supplies the JumpCloud auth header
    └── cve-mcp-launch.sh    # starts cve-mcp (pinned version) with keys from the keychain
```

Generated at runtime (git-ignored, and sensitive because they list unpatched hosts):

- `vuln-ledger.json` — finding state across runs (first seen, priority, status, last action)
- `vuln-report-YYYY-MM-DD.md` — the per-run report

---

## Prerequisites

- [Claude Code](https://code.claude.com/docs/en/overview)
- Node.js with `npx` (for cve-mcp)
- A JumpCloud admin account dedicated to the agent, with **MCP Server** turned on under **Settings → Features** in the Admin Portal
- **System Insights** enabled on your devices (needed for software inventory; without it the agent sees OS versions only)
- **Patch Management** in your JumpCloud package, if you want the agent to push OS and browser updates
- Optional: a free [NVD API key](https://nvd.nist.gov/developers/request-an-api-key) and a read-only GitHub token, both of which raise rate limits

## Quick start

```bash
# 1. Install the helper scripts where your user can't modify them
sudo install -d -m 755 /usr/local/lib/vulnops
sudo install -m 755 scripts/*.sh /usr/local/lib/vulnops/

# 2. Store the optional keys (macOS shown; see SECURITY-SETUP.md for Linux and 1Password)
security add-generic-password -s vulnops -a nvd-api-key -w
security add-generic-password -s vulnops -a github-token -w

# 3. Use the interactive config
cp mcp.json .mcp.json

# 4. Start Claude Code, run /mcp, choose "jumpcloud", and sign in as the agent admin
claude
```

Then run the agent:

```
Follow agents.md and run the fleet-vuln-triage workflow in skills.md.
```

**For the first run, start in report-only mode** so you can check its matching and prioritization before it changes anything:

```
Follow agents.md and run skills.md, but skip Step 6 (remediation). Report only.
```

## Running on a schedule

Scheduled runs can't complete a browser sign-in, so they use the headless config.

1. Store the JumpCloud API key for the agent admin:
   ```bash
   security add-generic-password -s vulnops -a jumpcloud-api-key -w
   ```
2. Switch configs:
   ```bash
   cp mcp.headless.json .mcp.json
   ```
3. Open `claude` in this folder once and accept the project trust prompt. Claude Code won't run the `headersHelper` until you do.
4. Schedule a daily run, for example with cron:
   ```cron
   45 6 * * 1-5  cd /path/to/vulnops && claude -p "Follow agents.md and run the fleet-vuln-triage workflow in skills.md." >> vulnops.log 2>&1
   ```

You can also create it as a scheduled task in Claude with push and email notifications turned on, which is how the agent reaches you for 0-day alerts and run summaries.

## Customizing

- **Protected groups** — edit the group names in `agents.md` to match your JumpCloud device groups.
- **SLAs and thresholds** — change the priority table in `agents.md`. `skills.md` reads it from there.
- **Autonomy** — to require approval for every patch, move P0/P1 from "What you may do on your own" to "What needs the operator's explicit yes first" in `agents.md`.
- **Stale-host cutoff** — 14 days by default (Step 1 of `skills.md`).

---

## Known limitations

- **JumpCloud's MCP server doesn't expose patch-policy management.** Its tools focus on users, devices, groups, applications, and Directory Insights. The agent tries `device_update` and `search_api` first. When neither can apply an update, it lists the exact console action for you rather than improvising.
- **Third-party apps without a JumpCloud patch path** are reported as "manual update needed", with the target version.
- **CVE matching depends on inventory quality.** Software names that don't map cleanly to a CPE are marked `confidence: low` in the report instead of being dropped or guessed.
- **Windows Credential Manager isn't supported by `secret.sh`.** On Windows, use the 1Password path by setting `VULNOPS_OP_VAULT`.

## Security

See [`SECURITY-SETUP.md`](SECURITY-SETUP.md). In short:

- No secret is stored in the config files or in environment variables.
- JumpCloud uses OAuth interactively, and keychain-backed headers for headless runs.
- Every credential is scoped to the minimum it needs.
- Every action the agent takes appears under its dedicated admin account in JumpCloud Directory Insights.

The agent treats everything returned by tools — advisories, PoC READMEs, device names, command output — as data, never as instructions.
