---
## Instructions for Claude Code
- At the start of every session, read this entire file before doing anything else.
- At the end of every session, automatically update the sections below: Current Status, Where We Left Off, Recent Changes, and Active Goals.
- Keep entries concise — bullet points only.
- Never delete previous content, only append or update the relevant sections.
- If a section does not exist yet, create it.
---

# Project: mp508
_Created: 2026-04-17_
_Last session: 2026-04-17_

## Description
Tooling and automation for managing the AudioCodes MP508 FXS VoIP gateway fleet (~1,400 devices).
Scripts for fleet health checks, alarm monitoring, firmware management, and config diffs.

## Tech Stack
- PowerShell (fleet management, alarm scripts, parallel runspaces)
- Python + openpyxl (config diff reports)
- DPAPI (credential storage — Windows user/machine bound, no plaintext)

## Structure
```
mp508/
├── Get-MP508Alarms.ps1     ← Alarm polling script (current)
├── docs/                   ← Documentation
│   └── MP508_Alarm_Poller_Guide.docx
├── mp508_ips.txt.example   ← Example IP list format
└── README.md
```

## Key Details
- Fleet: ~1,400 AudioCodes MP508 FXS gateways
- Credentials: DPAPI-stored (no plaintext passwords)
- Use PowerShell runspaces (not jobs) for parallel speed
- See also: `inhomeitservices` project for invoice app context

## Dev Workflow
- Edit scripts in VS Code or PowerShell ISE
- Test against a subset of IPs before running fleet-wide
- Use `mp508_ips.txt` (copy from `.example`) as input for fleet scripts

## Current Status

- `Get-MP508Alarms.ps1` is complete and functional (sequential polling, curl.exe, CSV output)
- No parallelism yet — runs one device at a time
- No DPAPI credential caching — prompts interactively every run
- Firmware management and config diff tooling not yet started

## Where We Left Off

- Session 2026-04-17: reviewed the existing codebase for the first time; no code changes made
- Script works end-to-end but is sequential and requires manual credential entry each run
- Next session: add PowerShell runspace-based parallelism and DPAPI credential storage

## Recent Changes

- 2026-04-17: Initial commit — `Get-MP508Alarms.ps1` (V4+ curl.exe-based poller), archive V1–V6, README, docs
- 2026-04-17: Cleaned up repo — removed `Alarm Script/` (duplicates), `archive/` (git covers history), `proxmox_mcp.log` (wrong project)

## Active Goals

- Add runspace parallelism to `Get-MP508Alarms.ps1` (significant speed gain across ~1,400 devices)
- Add DPAPI credential caching (store/retrieve creds so script runs unattended)
- Eventually: firmware management script, config diff tooling (Python + openpyxl)
