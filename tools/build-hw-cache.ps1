# ---------------------------------------------------------------------------
# build-hw-cache.ps1
#
# One-time, polite fetch of the linux-hardware.org LKDDb device pages listed in
# hw-cache-ids.txt into lsl-hw-cache/ (same file naming the runtime uses for
# its %TEMP% cache). Ships in the lsl-usb bundle so the install-time hardware
# rating needs no per-device network request for common hardware.
#
# Politeness: respects robots.txt Crawl-delay (>=10s). Uses a 12s gap between
# requests, and on HTTP 429 (rate limited) backs off 60s and retries up to 3
# times. Existing cache files are skipped (safe to re-run / resume).
#
# Usage:  pwsh tools/build-hw-cache.ps1 [-DelaySec 12] [-CacheDir <path>]
#                                          [-BaseUrl <url>]
#
# -BaseUrl (or the LSL_LHW_BASE_URL environment variable) points this build at a
# mirror of the LKDDb device pages instead of upstream. Upstream rate-limits
# aggressively (HTTP 429 after a handful of rapid requests; robots.txt
# Crawl-delay: 10s), which makes this build fragile; a mirror refreshed on a cron
# lets the bundle ship a complete, always-fresh cache with no dependence on the
# rate limiter. The cache file format is unchanged
# (lsl-lhw-<type>-<vid>-<did>.html), so only the base URL differs - which is why
# install.ps1 honours the same LSL_LHW_BASE_URL override.
#
# Remaining TODO (not a code change): stand up the mirror host itself. That is
# infrastructure outside this repo, so only the parameterisation lives here.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [int]$DelaySec = 12,
    [string]$IdFile,
    [string]$CacheDir,
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
if (-not $IdFile)   { $IdFile   = Join-Path $PSScriptRoot 'hw-cache-ids.txt' }
if (-not $CacheDir) { $CacheDir = Join-Path $PSScriptRoot '..' 'lsl-hw-cache' }
# -BaseUrl wins, then the environment override, then upstream.
if (-not $BaseUrl) { $BaseUrl = $env:LSL_LHW_BASE_URL }
if (-not $BaseUrl) { $BaseUrl = 'https://linux-hardware.org/' }
if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
$CacheDir = Resolve-Path $CacheDir -ErrorAction SilentlyContinue
if (-not $CacheDir) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
$CacheDir = Resolve-Path $CacheDir

Write-Host "Reading IDs from: $IdFile"
Write-Host "Writing cache to : $CacheDir"
Write-Host "Fetching from    : $BaseUrl"

$ids = @()
foreach ($line in (Get-Content $IdFile)) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    # strip trailing comment
    $id = $line -replace '#.*$', '' -replace '\s+$', '' -replace '^\s+', ''
    if ($id -match '^(pci|usb):[0-9a-fA-F]{4}-[0-9a-fA-F]{4}$') {
        $ids += $id.ToLowerInvariant()
    } else {
        Write-Warning "Skipping unrecognised line: $line"
    }
}
Write-Host "Parsed $($ids.Count) device IDs."

$lastReq = $null
$ok = 0; $noLkddb = 0; $skipped = 0; $failed = 0

function Get-Page {
    param([string]$Url)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 20000
    $req.UserAgent = 'lsl-usb/1.0 (hw-cache build; +https://github.com/linux-surface-lookalike/lsl-usb)'
    try {
        $resp = $req.GetResponse()
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            return @{ Html = $sr.ReadToEnd(); Status = 'OK' }
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 429) { return @{ Html = ''; Status = 'RATELIMITED' } }
        return @{ Html = ''; Status = "HTTP$code" }
    } catch {
        return @{ Html = ''; Status = 'ERROR' }
    }
}

$i = 0
foreach ($id in $ids) {
    $i++
    $file = Join-Path $CacheDir ("lsl-lhw-" + ($id -replace '[:]', '-') + '.html')
    if (Test-Path $file) {
        $skipped++
        continue
    }
    # polite gap
    if ($lastReq) {
        $elapsed = (Get-Date) - $lastReq
        if ($elapsed.TotalSeconds -lt $DelaySec) {
            Start-Sleep -Seconds ($DelaySec - $elapsed.TotalSeconds)
        }
    }
    $url = "${BaseUrl}?id=$id"
    $status = 'RATELIMITED'
    $html = ''
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $r = Get-Page -Url $url
        $status = $r.Status
        if ($status -eq 'OK') { $html = $r.Html; break }
        if ($status -eq 'RATELIMITED') {
            Write-Host "  [$($i)/$($ids.Count)] $id -> 429, backing off 60s (attempt $attempt)"
            Start-Sleep -Seconds 60
        } else {
            Write-Host "  [$($i)/$($ids.Count)] $id -> $status (attempt $attempt)"
            Start-Sleep -Seconds 5
        }
    }
    $lastReq = Get-Date
    if ($status -eq 'OK' -and $html) {
        Set-Content -Path $file -Value $html -Encoding UTF8
        # crude LKDDb coverage signal
        if ($html -match 'supported by kernel' -or $html -match 'Driver</td>' -or $html -match 'drivers/') {
            $ok++
            Write-Host "  [$($i)/$($ids.Count)] $id -> $([System.Text.Encoding]::UTF8.GetByteCount($html)) bytes (LKDDb entry present)"
        } else {
            $noLkddb++
            Write-Host "  [$($i)/$($ids.Count)] $id -> $([System.Text.Encoding]::UTF8.GetByteCount($html)) bytes (no LKDDb entry)"
        }
    } else {
        $failed++
        Write-Warning "  [$($i)/$($ids.Count)] $id -> FAILED ($status)"
    }
}

Write-Host ""
Write-Host "Done. cache=$CacheDir"
Write-Host "  with LKDDb entry : $ok"
Write-Host "  no LKDDb entry   : $noLkddb"
Write-Host "  skipped (exists) : $skipped"
Write-Host "  failed           : $failed"
