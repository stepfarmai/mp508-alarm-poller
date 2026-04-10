# MP508 Alarm Poller

PowerShell script to poll AudioCodes MP508 gateways (firmware 7.26) for active **Critical** and **Major** alarms via the REST API.

## How It Works

The AudioCodes 7.2x REST API returns alarms in two steps:
1. `GET /api/v1/alarms/active` — returns alarm IDs only (cursor-paginated)
2. `GET /api/v1/alarms/active/<id>` — returns full detail per alarm

The script uses `curl.exe` (built into Windows 11) instead of `Invoke-RestMethod` because the MP508 requests TLS renegotiation after the handshake, which .NET HttpWebRequest does not support.

## Requirements

- PowerShell 5.1+
- `curl.exe` (built into Windows 11 at `C:\Windows\System32\curl.exe`)

## Setup

1. Copy `mp508_ips.txt.example` to `mp508_ips.txt`
2. Add your MP508 IP addresses (one per line)
3. Run the script

## Usage

```powershell
# Basic — reads mp508_ips.txt in the current directory
.\Get-MP508Alarms.ps1

# Custom IP list file
.\Get-MP508Alarms.ps1 -IPListFile "C:\Scripts\sites.txt"

# Custom timeout
.\Get-MP508Alarms.ps1 -TimeoutSec 15

# Custom output folder
.\Get-MP508Alarms.ps1 -OutputPath "C:\Reports\MP508"
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-IPListFile` | `.\mp508_ips.txt` | Path to plain-text file with one IP per line |
| `-OutputPath` | `C:\Scripts\MP508` | Folder where CSV reports are written |
| `-TimeoutSec` | `10` | Per-request HTTP timeout in seconds |
| `-MaxAlarmsPerDevice` | `500` | Safety cap on alarms fetched per device |

## Output

Two timestamped CSV files are written to `OutputPath`:

| File | Contents |
|---|---|
| `MP508_Alarms_<timestamp>.csv` | IP, Severity, Source, Description, Time |
| `MP508_Unreachable_<timestamp>.csv` | IP, Status, Error Detail, Checked At |

## IP List Format

```
# Comments start with #
192.168.1.10
192.168.1.11
192.168.1.12:8443
```

Lines beginning with `#`, blank lines, and lines not matching a valid IP (with optional `:port`) are skipped.

## Archive

Previous versions of the script are in the `archive/` folder. The version history moved from `Invoke-RestMethod` (V1–V3) to `curl.exe` (V4+) to work around TLS renegotiation issues with the MP508.

## Docs

See `docs/MP508_Alarm_Poller_Guide.docx` for full usage documentation.
