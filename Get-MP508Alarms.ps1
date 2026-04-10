# ==============================================================================
#  Get-MP508Alarms.ps1
#  Polls AudioCodes MP508 gateways (firmware 7.26) for active Critical/Major alarms
#
#  Uses curl.exe (built into Windows 11) for all HTTPS calls instead of
#  Invoke-RestMethod. The MP508 requests TLS renegotiation after the handshake
#  which .NET HttpWebRequest does not support, causing "connection closed" errors.
#  curl.exe handles TLS renegotiation correctly.
#
#  How the AudioCodes 7.2x REST API works:
#    Step 1 - GET /api/v1/alarms/active       returns alarm IDs only (paginated)
#    Step 2 - GET /api/v1/alarms/active/<id>  returns full detail per alarm
#
#  Output: C:\Scripts\MP508
#    MP508_Alarms_<timestamp>.csv       - IP, Severity, Source, Description, Time
#    MP508_Unreachable_<timestamp>.csv  - IP, Status, Error Detail, Checked At
#
#  Requirements: PowerShell 5.1+, curl.exe (built into Windows 11)
#  Usage:        .\Get-MP508Alarms.ps1
#                .\Get-MP508Alarms.ps1 -IPListFile "C:\Scripts\sites.txt"
#                .\Get-MP508Alarms.ps1 -TimeoutSec 15
# ==============================================================================

[CmdletBinding()]
param (
    [string]$IPListFile          = ".\mp508_ips.txt",
    [string]$OutputPath          = "C:\Scripts\MP508",
    [int]$TimeoutSec             = 10,
    [int]$MaxAlarmsPerDevice     = 500
)

$TargetSeverities = @("Critical", "Major")

# ------------------------------------------------------------------------------
# Confirm curl.exe is available
# ------------------------------------------------------------------------------
$CurlPath = (Get-Command "curl.exe" -ErrorAction SilentlyContinue).Source
if (-not $CurlPath) {
    # Fallback to known Windows 11 location
    if (Test-Path "C:\Windows\System32\curl.exe") {
        $CurlPath = "C:\Windows\System32\curl.exe"
    } else {
        Write-Host ""
        Write-Host "  ERROR: curl.exe not found." -ForegroundColor Red
        Write-Host "  curl.exe is built into Windows 11 at C:\Windows\System32\curl.exe" -ForegroundColor Yellow
        Write-Host "  If it is missing, download it from https://curl.se/windows/" -ForegroundColor Yellow
        exit 1
    }
}

# ------------------------------------------------------------------------------
# Validate IP list
# ------------------------------------------------------------------------------
if (-not (Test-Path $IPListFile)) {
    Write-Host ""
    Write-Host "  ERROR: IP list file not found: $IPListFile" -ForegroundColor Red
    Write-Host "  Create a plain-text file with one IP per line and re-run." -ForegroundColor Yellow
    exit 1
}

# Strip http:// or https:// prefix if present, keep optional :port
$IPs = Get-Content $IPListFile |
       ForEach-Object { $_.Trim() } |
       Where-Object   { $_ -ne "" -and $_ -notmatch "^#" } |
       ForEach-Object { $_ -replace '^https?://', '' } |
       Where-Object   { $_ -match '^\d{1,3}(\.\d{1,3}){3}(:\d+)?$' }

if ($IPs.Count -eq 0) {
    Write-Host "  ERROR: No valid IP addresses found in $IPListFile" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host "  |   AudioCodes MP508 Alarm Poller        |" -ForegroundColor Cyan
Write-Host "  |   Firmware 7.26  |  REST API v1        |" -ForegroundColor Cyan
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Devices loaded : $($IPs.Count)" -ForegroundColor White
Write-Host "  Severities     : $($TargetSeverities -join ', ')" -ForegroundColor White
Write-Host "  curl.exe       : $CurlPath" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------------------
# Credentials - Read-Host bypasses Windows SSO / credential manager
# ------------------------------------------------------------------------------
Write-Host "  Enter MP508 credentials (SSO will not be used)" -ForegroundColor Yellow
Write-Host ""
$Username = Read-Host "  Username"

if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Host "  ERROR: Username cannot be blank." -ForegroundColor Red
    exit 1
}

$SecurePassword = Read-Host "  Password" -AsSecureString
$BSTR           = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$Password       = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Host "  ERROR: Password cannot be blank." -ForegroundColor Red
    exit 1
}

$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))

Write-Host ""
Write-Host "  Logging in as  : $Username" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------------------------
# Ensure output folder exists
# ------------------------------------------------------------------------------
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
    Write-Host "  Created output folder: $OutputPath" -ForegroundColor DarkGray
}

$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$AlarmCSV   = Join-Path $OutputPath "MP508_Alarms_$Timestamp.csv"
$UnreachCSV = Join-Path $OutputPath "MP508_Unreachable_$Timestamp.csv"

$AlarmRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$UnreachRows = [System.Collections.Generic.List[PSCustomObject]]::new()

# ==============================================================================
# Helper - call curl.exe and return parsed JSON + HTTP status code
# Returns hashtable: { ok=$true/$false; status=<int>; data=<object>; error=<string> }
# ==============================================================================
function Invoke-CurlJson {
    param(
        [string]$Url,
        [string]$AuthBase64,
        [int]$TimeoutSec
    )

    # -k  = ignore cert errors (self-signed / invalid CA)
    # -s  = silent (no progress bar)
    # -w  = append HTTP status code on its own line after body
    # --max-time = total timeout in seconds
    # --retry 0 = no automatic retries (we handle that ourselves)
    $curlArgs = @(
        "-k", "-s",
        "-w", "`n%{http_code}",
        "--max-time", $TimeoutSec,
        "--retry", "0",
        "-H", "Authorization: Basic $AuthBase64",
        "-H", "Accept: application/json",
        $Url
    )

    try {
        $raw = & $CurlPath @curlArgs 2>&1

        # Last line is the HTTP status code, everything before is the body
        $lines      = $raw -split "`n"
        $statusLine = ($lines[-1]).Trim()
        $body       = ($lines[0..($lines.Length - 2)] -join "`n").Trim()

        $statusCode = 0
        [int]::TryParse($statusLine, [ref]$statusCode) | Out-Null

        if ($statusCode -eq 0) {
            # curl failed before getting a response (timeout, DNS, refused, etc.)
            return @{ ok=$false; status=0; data=$null; error=$raw -join " " }
        }

        $data = $null
        if ($body -ne "" -and $statusCode -lt 400) {
            try { $data = $body | ConvertFrom-Json } catch { }
        }

        return @{ ok=($statusCode -lt 400); status=$statusCode; data=$data; error=$body }
    }
    catch {
        return @{ ok=$false; status=0; data=$null; error=$_.Exception.Message }
    }
}

# ==============================================================================
# Main polling loop
# ==============================================================================
$DeviceNum = 0
foreach ($IP in $IPs) {
    $DeviceNum++
    $BaseUrl = "https://$IP"

    Write-Progress -Activity "Polling MP508 devices" `
                   -Status   "[$DeviceNum/$($IPs.Count)]  $IP" `
                   -PercentComplete ([int](($DeviceNum / $IPs.Count) * 100))

    # --------------------------------------------------------------------------
    # Step 1 - collect all alarm IDs via cursor pagination
    # --------------------------------------------------------------------------
    $AllIDs    = [System.Collections.Generic.List[string]]::new()
    $Cursor    = ""
    $Failed    = $false
    $FailMsg   = ""
    $FailStatus = 0

    do {
                # No ?count parameter - use device default (20 per page)
        # Some MP508 firmware builds return 400 if unknown query params are sent
        $Url  = "$BaseUrl/api/v1/alarms/active"
        if ($Cursor -ne "") { $Url += "?after=$Cursor" }

        $Resp = Invoke-CurlJson -Url $Url -AuthBase64 $b64 -TimeoutSec $TimeoutSec

        if (-not $Resp.ok) {
            $Failed     = $true
            $FailMsg    = $Resp.error
            $FailStatus = $Resp.status
            break
        }

        if ($Resp.data -and $Resp.data.alarms) {
            foreach ($a in $Resp.data.alarms) { $AllIDs.Add([string]$a.id) }
        }

        # Follow cursor to next page; "-1" means no more pages
        $Cursor = ""
        if ($Resp.data.cursor -and ([string]$Resp.data.cursor.after) -ne "-1") {
            $Cursor = [string]$Resp.data.cursor.after
        }

        if ($AllIDs.Count -ge $MaxAlarmsPerDevice) { break }

    } while ($Cursor -ne "")

    # --------------------------------------------------------------------------
    # Handle connection / auth failure
    # --------------------------------------------------------------------------
    if ($Failed) {
        $Status = if     ($FailStatus -eq 401)                              { "Auth Failure" }
                  elseif ($FailStatus -eq 403)                              { "Forbidden - check user privilege level" }
                  elseif ($FailStatus -eq 0 -and $FailMsg -match "timed out|timeout|Timeout") { "Unreachable - Timeout" }
                  elseif ($FailStatus -eq 0)                                { "Unreachable" }
                  else                                                       { "HTTP $FailStatus Error" }

        $UnreachRows.Add([PSCustomObject]@{
            "IP Address"   = $IP
            "Status"       = $Status
            "Error Detail" = $FailMsg.Substring(0, [Math]::Min(200, $FailMsg.Length))
            "Checked At"   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        Write-Host ("  [FAIL] {0,-20}  {1}" -f $IP, $Status) -ForegroundColor Red
        # Print response body for non-zero status codes to aid diagnosis
        if ($FailStatus -gt 0 -and $FailMsg -ne "") {
            Write-Host ("          Response body: {0}" -f $FailMsg.Substring(0, [Math]::Min(120, $FailMsg.Length))) -ForegroundColor DarkYellow
        }
        continue
    }

    # --------------------------------------------------------------------------
    # Step 2 - fetch detail for each alarm, filter by severity
    # --------------------------------------------------------------------------
    $MatchCount = 0

    foreach ($AlarmID in $AllIDs) {
        $DetailUrl  = "$BaseUrl/api/v1/alarms/active/$AlarmID"
        $DetailResp = Invoke-CurlJson -Url $DetailUrl -AuthBase64 $b64 -TimeoutSec $TimeoutSec

        if (-not $DetailResp.ok -or $null -eq $DetailResp.data) { continue }

        $D   = $DetailResp.data
        $Sev = if ($D.severity)    { $D.severity }    else { "Unknown" }

        if ($TargetSeverities -notcontains $Sev) { continue }

        $Source = if ($D.source)      { $D.source }      else { "N/A" }
        $Desc   = if ($D.description) { $D.description } else { "N/A" }
        $Time   = if ($D.date)        { $D.date }
                  elseif ($D.time)    { $D.time }
                  elseif ($D.dateTime){ $D.dateTime }
                  else                { "N/A" }

        $AlarmRows.Add([PSCustomObject]@{
            "IP Address"  = $IP
            "Severity"    = $Sev
            "Source"      = $Source
            "Description" = $Desc
            "Time"        = $Time
        })
        $MatchCount++
    }

    if ($MatchCount -gt 0) {
        Write-Host ("  [OK]  {0,-20}  {1,3} alarm(s)  |  {2} Critical/Major" -f `
            $IP, $AllIDs.Count, $MatchCount) -ForegroundColor Yellow
    } else {
        Write-Host ("  [OK]  {0,-20}  {1,3} alarm(s)  |  none Critical/Major" -f `
            $IP, $AllIDs.Count) -ForegroundColor Green
    }
}

Write-Progress -Activity "Polling MP508 devices" -Completed

# ==============================================================================
# Write CSVs
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
# Summary
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
