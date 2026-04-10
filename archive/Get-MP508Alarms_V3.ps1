# ==============================================================================
#  Get-MP508Alarms.ps1
#  Polls AudioCodes MP508 gateways (firmware 7.26) for active Critical/Major alarms
#  via the REST API at /api/v1/alarms/active
#
#  How the AudioCodes 7.2x REST API works for alarms:
#    Step 1 - GET /api/v1/alarms/active          -> returns list of alarm IDs only
#             (cursor-based pagination, 20 per page by default)
#    Step 2 - GET /api/v1/alarms/active/<id>     -> returns full details per alarm
#             (severity, source, description, date)
#
#  Output (C:\Temp):
#    MP508_Alarms_<timestamp>.csv       - IP, Severity, Source, Description, Time
#    MP508_Unreachable_<timestamp>.csv  - IP, Status, Error Detail, Checked At
#
#  Requirements : PowerShell 5.1+
#  Usage        : .\Get-MP508Alarms.ps1
#                 .\Get-MP508Alarms.ps1 -IPListFile "C:\Scripts\sites.txt"
#                 .\Get-MP508Alarms.ps1 -TimeoutSec 15 -MaxAlarmsPerDevice 200
# ==============================================================================

[CmdletBinding()]
param (
    # Path to plain-text file -- one IP per line
    [string]$IPListFile = ".\mp508_ips.txt",

    # Output folder
    [string]$OutputPath = "C:\Scripts\MP508",

    # Per-request HTTP timeout in seconds
    [int]$TimeoutSec = 10,

    # Safety cap: max alarms to fetch per device (prevents runaway pagination)
    [int]$MaxAlarmsPerDevice = 500
)

# -- Severity strings to collect (firmware 7.2x returns string values) ---------
$TargetSeverities = @("Critical", "Major")

# -- Suppress SSL certificate errors (self-signed certs on MP508) --------------
function Disable-SSLValidation {
    if (-not ([System.Management.Automation.PSTypeName]"TrustAllCertsPolicy").Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate cert,
        WebRequest request, int certProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol  =
        [System.Net.SecurityProtocolType]::Tls12 -bor
        [System.Net.SecurityProtocolType]::Tls11 -bor
        [System.Net.SecurityProtocolType]::Tls
}

# -- Validate IP list -----------------------------------------------------------
if (-not (Test-Path $IPListFile)) {
    Write-Host ""
    Write-Host "  ERROR: IP list file not found: $IPListFile" -ForegroundColor Red
    Write-Host "  Create a plain-text file with one IP per line and re-run." -ForegroundColor Yellow
    Write-Host "  Example:  .\Get-MP508Alarms.ps1 -IPListFile C:\Scripts\sites.txt" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$IPs = Get-Content $IPListFile |
       ForEach-Object { $_.Trim() } |
       Where-Object   { $_ -ne "" -and $_ -notmatch "^#" -and $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }

if ($IPs.Count -eq 0) {
    Write-Host "  ERROR: No valid IP addresses found in $IPListFile" -ForegroundColor Red
    exit 1
}

# -- Prompt for credentials -----------------------------------------------------
Write-Host ""
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host "  |   AudioCodes MP508 Alarm Poller        |" -ForegroundColor Cyan
Write-Host "  |   Firmware 7.26  |  REST API v1        |" -ForegroundColor Cyan
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Devices loaded : $($IPs.Count)" -ForegroundColor White
Write-Host "  Severities     : $($TargetSeverities -join ', ')" -ForegroundColor White
Write-Host ""

# Store message in a variable first - avoids PowerShell misreading the
# parentheses as a subexpression when the string is passed inline to -Message
$CredMsg = "Enter MP508 username and password - used for all devices"
$Cred    = Get-Credential -Message $CredMsg

if ($null -eq $Cred) {
    Write-Host ""
    Write-Host "  ERROR: No credentials provided. Exiting." -ForegroundColor Red
    exit 1
}

$Username = $Cred.UserName
$Password = $Cred.GetNetworkCredential().Password

if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Host ""
    Write-Host "  ERROR: Username is blank. Please re-run and enter credentials." -ForegroundColor Red
    exit 1
}

$AuthBytes  = [System.Text.Encoding]::ASCII.GetBytes("${Username}:${Password}")
$AuthBase64 = [Convert]::ToBase64String($AuthBytes)
$Headers    = @{
    "Authorization" = "Basic $AuthBase64"
    "Accept"        = "application/json"
}

Write-Host "  Logging in as  : $Username" -ForegroundColor White

# -- Ensure output folder -------------------------------------------------------
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
    Write-Host "  Created output folder: $OutputPath" -ForegroundColor DarkGray
}

$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$AlarmCSV   = Join-Path $OutputPath "MP508_Alarms_$Timestamp.csv"
$UnreachCSV = Join-Path $OutputPath "MP508_Unreachable_$Timestamp.csv"

$AlarmRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$UnreachRows = [System.Collections.Generic.List[PSCustomObject]]::new()

Disable-SSLValidation

# ==============================================================================
#  Helper - fetch one page of alarm IDs from the list endpoint
#  The 7.2x list endpoint returns only {id, description, url} per alarm.
#  Full details (severity, source, date) require a per-alarm GET.
# ==============================================================================
function Get-AlarmPage {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [string]$AfterCursor = ""
    )

    $Url = "$BaseUrl/api/v1/alarms/active?count=50"
    if ($AfterCursor -ne "") { $Url += "&after=$AfterCursor" }

    $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get `
                                  -TimeoutSec $TimeoutSec -ErrorAction Stop

    $IDs = @()
    if ($Response.alarms) {
        $IDs = @($Response.alarms | ForEach-Object { $_.id })
    }

    # cursor.after = "-1" means no more pages
    $NextCursor = ""
    if ($Response.cursor -and $Response.cursor.after -ne "-1") {
        $NextCursor = $Response.cursor.after
    }

    return @{ ids = $IDs; nextCursor = $NextCursor }
}

# ==============================================================================
#  Helper - fetch full detail for a single alarm ID
# ==============================================================================
function Get-AlarmDetail {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [string]$AlarmId
    )

    try {
        return Invoke-RestMethod -Uri "$BaseUrl/api/v1/alarms/active/$AlarmId" `
                                 -Headers $Headers -Method Get `
                                 -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        return $null
    }
}

# ==============================================================================
#  Main polling loop
# ==============================================================================
$DeviceNum = 0
foreach ($IP in $IPs) {
    $DeviceNum++
    $BaseUrl = "https://$IP"

    Write-Progress -Activity "Polling MP508 devices" `
                   -Status   "[$DeviceNum/$($IPs.Count)]  $IP" `
                   -PercentComplete ([int](($DeviceNum / $IPs.Count) * 100))

    try {
        # -- Step 1: collect all alarm IDs via cursor pagination ----------------
        $AllIDs    = [System.Collections.Generic.List[string]]::new()
        $Cursor    = ""
        $PageCount = 0

        do {
            $Page = Get-AlarmPage -BaseUrl $BaseUrl -Headers $Headers `
                                  -TimeoutSec $TimeoutSec -AfterCursor $Cursor

            foreach ($id in $Page.ids) { $AllIDs.Add($id) }

            $Cursor = $Page.nextCursor
            $PageCount++

            if ($AllIDs.Count -ge $MaxAlarmsPerDevice) { break }

        } while ($Cursor -ne "")

        # -- Step 2: fetch detail for each alarm, filter by severity ------------
        $MatchCount = 0

        foreach ($AlarmID in $AllIDs) {
            $Detail = Get-AlarmDetail -BaseUrl $BaseUrl -Headers $Headers `
                                      -TimeoutSec $TimeoutSec -AlarmId $AlarmID

            if ($null -eq $Detail) { continue }

            # 7.2x severity is a string: "Critical", "Major", "Minor", etc.
            $Sev = if ($Detail.severity) { $Detail.severity } else { "Unknown" }

            if ($TargetSeverities -notcontains $Sev) { continue }

            $Source = if ($Detail.source)       { $Detail.source }       else { "N/A" }
            $Desc   = if ($Detail.description)  { $Detail.description }  else { "N/A" }

            # 7.2x returns ISO 8601 timestamp in the 'date' field
            $Time   = if ($Detail.date)         { $Detail.date }
                      elseif ($Detail.time)     { $Detail.time }
                      elseif ($Detail.dateTime) { $Detail.dateTime }
                      else                      { "N/A" }

            $AlarmRows.Add([PSCustomObject]@{
                "IP Address"  = $IP
                "Severity"    = $Sev
                "Source"      = $Source
                "Description" = $Desc
                "Time"        = $Time
            })
            $MatchCount++
        }

        # -- Console feedback ---------------------------------------------------
        if ($MatchCount -gt 0) {
            Write-Host ("  [OK]  {0,-18}  {1,3} alarm(s) found  |  {2} Critical/Major" -f `
                $IP, $AllIDs.Count, $MatchCount) -ForegroundColor Yellow
        } else {
            Write-Host ("  [OK]  {0,-18}  {1,3} alarm(s) found  |  none Critical/Major" -f `
                $IP, $AllIDs.Count) -ForegroundColor Green
        }

    } catch {
        $Msg = $_.Exception.Message

        $Status = if     ($Msg -match "timed out|Unable to connect|No connection|refused|unreachable") { "Unreachable" }
                  elseif ($Msg -match "401|Unauthorized")  { "Auth Failure" }
                  elseif ($Msg -match "403|Forbidden")     { "Forbidden - check user privilege level" }
                  else                                     { "Error: $($Msg.Substring(0, [Math]::Min(80,$Msg.Length)))" }

        $UnreachRows.Add([PSCustomObject]@{
            "IP Address"   = $IP
            "Status"       = $Status
            "Error Detail" = $Msg
            "Checked At"   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })

        Write-Host ("  [FAIL] {0,-18}  {1}" -f $IP, $Status) -ForegroundColor Red
    }
}

Write-Progress -Activity "Polling MP508 devices" -Completed

# ==============================================================================
#  Write CSVs
# ==============================================================================
Write-Host ""
Write-Host "  Writing output files..." -ForegroundColor DarkGray

if ($AlarmRows.Count -gt 0) {
    $AlarmRows | Export-Csv -Path $AlarmCSV -NoTypeInformation -Encoding UTF8
} else {
    [PSCustomObject]@{
        "IP Address" = ""; "Severity" = ""; "Source" = ""; "Description" = ""; "Time" = ""
    } | Export-Csv -Path $AlarmCSV -NoTypeInformation -Encoding UTF8
}

if ($UnreachRows.Count -gt 0) {
    $UnreachRows | Export-Csv -Path $UnreachCSV -NoTypeInformation -Encoding UTF8
} else {
    [PSCustomObject]@{
        "IP Address" = ""; "Status" = ""; "Error Detail" = ""; "Checked At" = ""
    } | Export-Csv -Path $UnreachCSV -NoTypeInformation -Encoding UTF8
}

# ==============================================================================
#  Summary
# ==============================================================================
$AlarmColor   = if ($AlarmRows.Count   -gt 0) { "Yellow" } else { "Green" }
$UnreachColor = if ($UnreachRows.Count -gt 0) { "Red"    } else { "Green" }

Write-Host ""
Write-Host "  ============================================" -ForegroundColor DarkGray
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor DarkGray
Write-Host ("  Devices polled   : {0}" -f $IPs.Count)
Write-Host ("  Critical/Major   : {0}" -f $AlarmRows.Count)   -ForegroundColor $AlarmColor
Write-Host ("  Unreachable      : {0}" -f $UnreachRows.Count) -ForegroundColor $UnreachColor
Write-Host ""
Write-Host ("  Alarms CSV    -> {0}" -f $AlarmCSV)   -ForegroundColor Cyan
Write-Host ("  Unreachable   -> {0}" -f $UnreachCSV) -ForegroundColor Cyan
Write-Host ""
