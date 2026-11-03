#Requires -Version 5.1
<#
.SYNOPSIS
    Resumable downloader for large Google Drive files (built for a 4.27 GiB .7z).

.DESCRIPTION
    * Accepts either a direct drive.usercontent.google.com link or a plain
      drive.google.com share/view link (it follows Drive's "virus scan" confirm page).
    * Streams the response straight to disk, so multi-gigabyte files never sit in RAM.
    * Resumes from a .part file with HTTP Range requests after an interruption.
    * Retries dropped or stalled connections with exponential backoff.
    * Reports percentage, speed and ETA, then verifies the size and the 7z signature.

.PARAMETER Url
    The Google Drive link. Defaults to the DayZ Epoch client archive.

.PARAMETER OutFile
    Full path of the finished file. Defaults to the name Drive reports, saved next to this script.

.PARAMETER MaxRetries
    How many times a broken attempt may be retried before giving up.

.PARAMETER StallTimeoutSeconds
    Abort and resume if no data arrives for this many seconds.

.EXAMPLE
    .\Get-DriveFile.ps1

.EXAMPLE
    .\Get-DriveFile.ps1 -Url 'https://drive.google.com/file/d/FILE_ID/view' -OutFile 'D:\stuff.7z'
#>
[CmdletBinding()]
param(
    [string]$Url   = 'https://drive.usercontent.google.com/download?id=19iCJevU008g311vsxJNR0PjYmkSv36YK&export=download&authuser=0&confirm=t&uuid=f9ff194b-1730-46cd-99b7-ab37067a23ec&at=AMrWOn2KicdgFMs0Czlvh5KfjhKj%3A1793582616560',
    [string]$OutFile,
    [int]$MaxRetries = 20,
    [int]$StallTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

# ---------------------------------------------------------------- helpers ----

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Eta {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 0 -or [double]::IsInfinity($Span.TotalSeconds)) { return '--:--:--' }
    return ('{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
}

function Get-FileIdFromUrl {
    param([string]$Url)
    foreach ($pattern in @('(?:[?&](?:id|id%3D))=?([A-Za-z0-9_-]{10,})', '/file/d/([A-Za-z0-9_-]{10,})', '/d/([A-Za-z0-9_-]{10,})')) {
        $m = [regex]::Match($Url, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# Pull the real download URL out of Drive's "can't scan this file for viruses" page.
function Get-ConfirmUrl {
    param([string]$Html, [string]$BaseUrl)

    $form = [regex]::Match($Html, '(?is)<form[^>]*action\s*=\s*"([^"]+)"[^>]*>(.*?)</form>')
    if ($form.Success) {
        $action = [System.Net.WebUtility]::HtmlDecode($form.Groups[1].Value)
        try { $action = (New-Object System.Uri((New-Object System.Uri($BaseUrl)), $action)).AbsoluteUri } catch { }

        $pairs = New-Object System.Collections.Generic.List[string]
        foreach ($input in [regex]::Matches($form.Groups[2].Value, '(?is)<input[^>]*>')) {
            $name  = [regex]::Match($input.Value, '(?i)name\s*=\s*"([^"]*)"').Groups[1].Value
            $value = [regex]::Match($input.Value, '(?i)value\s*=\s*"([^"]*)"').Groups[1].Value
            if ($name) {
                $pairs.Add(('{0}={1}' -f [uri]::EscapeDataString($name),
                            [uri]::EscapeDataString([System.Net.WebUtility]::HtmlDecode($value))))
            }
        }
        $sep = if ($action.Contains('?')) { '&' } else { '?' }
        if ($pairs.Count -gt 0) { return $action + $sep + ($pairs -join '&') }
        return $action
    }

    $link = [regex]::Match($Html, '(?is)href\s*=\s*"([^"]*(?:drive\.usercontent\.google\.com|drive\.google\.com/uc)[^"]*)"')
    if ($link.Success) { return [System.Net.WebUtility]::HtmlDecode($link.Groups[1].Value) }

    return $null
}

# Follow redirects and confirm pages until the URL actually serves the binary.
function Resolve-FinalUrl {
    param($Client, [string]$StartUrl)

    $url = $StartUrl
    for ($hop = 0; $hop -lt 6; $hop++) {
        $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $url
        [void]$request.Headers.TryAddWithoutValidation('Range', 'bytes=0-0')
        $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            $status = [int]$response.StatusCode
            $contentType = ''
            if ($response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.MediaType }

            if ($contentType -like 'text/html*') {
                $html = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $next = Get-ConfirmUrl -Html $html -BaseUrl $url
                if (-not $next) {
                    $title = [regex]::Match($html, '(?is)<title>(.*?)</title>').Groups[1].Value.Trim()
                    $detail = if ($title) { " ('$title')" } else { '' }
                    throw "Google Drive returned an HTML page instead of the file$detail. The link may have expired or hit its download quota."
                }
                Write-Log 'Drive confirm page returned - following the real download link.' 'Yellow'
                $url = $next
                continue
            }

            if ($status -lt 200 -or $status -ge 300) {
                throw "Server returned HTTP $status $($response.ReasonPhrase)."
            }
            return $url
        }
        finally {
            $response.Dispose()
            $request.Dispose()
        }
    }
    throw 'Too many redirects while resolving the Google Drive link.'
}

# Size + filename without downloading the payload.
function Get-RemoteInfo {
    param($Client, [string]$Url)

    $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $Url
    [void]$request.Headers.TryAddWithoutValidation('Range', 'bytes=0-0')
    $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        $contentType = ''
        if ($response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.MediaType }
        if ($contentType -like 'text/html*') { throw 'Got an HTML page instead of the file.' }
        if (-not $response.IsSuccessStatusCode) {
            throw "Server returned HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)."
        }

        $length = 0L
        $range = $response.Content.Headers.ContentRange
        if ($range -and $range.HasLength) { $length = [long]$range.Length }
        elseif ($response.Content.Headers.ContentLength) { $length = [long]$response.Content.Headers.ContentLength }

        $name = $null
        $cd = $response.Content.Headers.ContentDisposition
        if ($cd -and $cd.FileName) { $name = [System.IO.Path]::GetFileName($cd.FileName.Trim('"')) }

        return [pscustomobject]@{ Url = $Url; Length = $length; FileName = $name }
    }
    finally {
        $response.Dispose()
        $request.Dispose()
    }
}

# Streamed, resumable transfer of the body into the .part file.
function Invoke-Download {
    param($Client, [string]$Url, [string]$TargetPath, [long]$TotalLength)

    $partPath = "$TargetPath.part"
    $buffer   = New-Object byte[] (1MB)
    $attempt  = 0

    while ($true) {
        $attempt++
        $have = 0L
        if (Test-Path -LiteralPath $partPath) { $have = (Get-Item -LiteralPath $partPath).Length }
        if ($TotalLength -gt 0 -and $have -ge $TotalLength) { return $partPath }

        try {
            if ($have -gt 0) { Write-Log ('Resuming at {0} ({1})' -f (Format-Size $have), "attempt $attempt") 'Yellow' }

            $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $Url
            if ($have -gt 0) { [void]$request.Headers.TryAddWithoutValidation('Range', "bytes=$have-") }

            $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

            if ($response.StatusCode -eq [System.Net.HttpStatusCode]::OK -and $have -gt 0) {
                Write-Log 'Server ignored the resume request - restarting from 0.' 'Yellow'
                $have = 0L
                if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }
            }
            if (-not $response.IsSuccessStatusCode) {
                throw "Server returned HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) while downloading."
            }

            $mode = if ($have -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = [System.IO.File]::Open($partPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $netStream  = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $watch      = [System.Diagnostics.Stopwatch]::StartNew()
            $sessionBytes = 0L
            $lastReport = 0.0

            try {
                while ($true) {
                    $cts = New-Object System.Threading.CancellationTokenSource
                    $cts.CancelAfter($StallTimeoutSeconds * 1000)
                    try {
                        $read = $netStream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
                    }
                    catch [System.OperationCanceledException] {
                        throw "No data received for $StallTimeoutSeconds seconds - connection stalled."
                    }
                    finally { $cts.Dispose() }

                    if ($read -le 0) { break }

                    $fileStream.Write($buffer, 0, $read)
                    $have += $read
                    $sessionBytes += $read

                    if ($watch.Elapsed.TotalSeconds - $lastReport -ge 5) {
                        $lastReport = $watch.Elapsed.TotalSeconds
                        $speed = if ($watch.Elapsed.TotalSeconds -gt 0) { $sessionBytes / $watch.Elapsed.TotalSeconds } else { 0 }
                        if ($TotalLength -gt 0) {
                            $pct = 100.0 * $have / $TotalLength
                            $eta = if ($speed -gt 0) { [TimeSpan]::FromSeconds(($TotalLength - $have) / $speed) } else { [TimeSpan]::Zero }
                            Write-Log ('{0,5:N1}%  {1} / {2}  {3}/s  ETA {4}' -f $pct, (Format-Size $have), (Format-Size $TotalLength), (Format-Size $speed), (Format-Eta $eta))
                            if ($Host.Name -eq 'ConsoleHost') {
                                Write-Progress -Activity 'Downloading' -Status ('{0} / {1}' -f (Format-Size $have), (Format-Size $TotalLength)) `
                                    -PercentComplete ([int][Math]::Min(100, $pct)) -SecondsRemaining ([int][Math]::Max(0, $eta.TotalSeconds))
                            }
                        }
                        else {
                            Write-Log ('{0} downloaded  {1}/s' -f (Format-Size $have), (Format-Size $speed))
                        }
                    }
                }
                $fileStream.Flush()
            }
            finally {
                $fileStream.Dispose()
                $netStream.Dispose()
                $response.Dispose()
                $request.Dispose()
                if ($Host.Name -eq 'ConsoleHost') { Write-Progress -Activity 'Downloading' -Completed }
            }

            if ($TotalLength -gt 0 -and $have -lt $TotalLength) {
                throw "Connection closed early at $have of $TotalLength bytes."
            }
            return $partPath
        }
        catch {
            $message = $_.Exception.Message
            if ($attempt -ge $MaxRetries) {
                throw "Giving up after $attempt attempts. Last error: $message"
            }
            $wait = [int][Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Log "Attempt $attempt failed: $message" 'Red'
            Write-Log "Retrying in $wait s (the .part file is kept, so nothing restarts from zero)." 'Yellow'
            Start-Sleep -Seconds $wait
        }
    }
}

# ------------------------------------------------------------------- main ----

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$startedAt = [System.Diagnostics.Stopwatch]::StartNew()

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$handler.UseCookies = $true
$handler.CookieContainer = New-Object System.Net.CookieContainer
$handler.MaxConnectionsPerServer = 1

$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')

$fileId = Get-FileIdFromUrl $Url
$candidates = New-Object System.Collections.Generic.List[string]
$candidates.Add($Url)
if ($fileId) { $candidates.Add("https://drive.google.com/uc?export=download&id=$fileId") }

$plan = $null
foreach ($candidate in $candidates) {
    try {
        $finalUrl = Resolve-FinalUrl -Client $client -StartUrl $candidate
        $plan = Get-RemoteInfo -Client $client -Url $finalUrl
        break
    }
    catch {
        Write-Log "Link rejected: $($_.Exception.Message)" 'Red'
    }
}
if (-not $plan) { throw 'Could not resolve a working download link for this Google Drive file.' }

if (-not $OutFile) {
    $name = if ($plan.FileName) { $plan.FileName } else { 'download.7z' }
    $OutFile = Join-Path $scriptDir $name
}
$OutFile = [System.IO.Path]::GetFullPath($OutFile)
$outDir  = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Write-Log "Source     : $($plan.Url)" 'Cyan'
Write-Log "Target     : $OutFile" 'Cyan'
if ($plan.Length -gt 0) { Write-Log ("Size       : {0} ({1:N0} bytes)" -f (Format-Size $plan.Length), $plan.Length) 'Cyan' }
Write-Log "Resume     : enabled (.part file)" 'Cyan'

if ((Test-Path -LiteralPath $OutFile) -and $plan.Length -gt 0 -and (Get-Item -LiteralPath $OutFile).Length -eq $plan.Length) {
    Write-Log 'File is already fully downloaded - nothing to do.' 'Green'
    return
}

$free = (Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($OutFile).TrimEnd(':', '\'))).Free
if ($plan.Length -gt 0 -and $free -lt $plan.Length) {
    throw ('Not enough free space: need {0}, only {1} available.' -f (Format-Size $plan.Length), (Format-Size $free))
}

$partPath = Invoke-Download -Client $client -Url $plan.Url -TargetPath $OutFile -TotalLength $plan.Length

$length = (Get-Item -LiteralPath $partPath).Length
if ($plan.Length -gt 0 -and $length -ne $plan.Length) {
    throw "Downloaded $length bytes but expected $($plan.Length)."
}

Move-Item -LiteralPath $partPath -Destination $OutFile -Force

# 7-Zip archives start with "7z" + BC AF 27 1C; anything else means the page was served instead.
$signature = New-Object byte[] 6
$reader = [System.IO.File]::OpenRead($OutFile)
try { [void]$reader.Read($signature, 0, 6) } finally { $reader.Dispose() }

if ($signature[0] -eq 0x37 -and $signature[1] -eq 0x7A -and $signature[2] -eq 0xBC -and $signature[3] -eq 0xAF -and $signature[4] -eq 0x27 -and $signature[5] -eq 0x1C) {
    Write-Log 'Verified: file signature is a valid 7-Zip archive.' 'Green'
}
elseif ($signature[0] -eq 0x3C) {
    Write-Log 'WARNING: the file looks like HTML, not a 7z archive. The link probably expired.' 'Red'
}
else {
    Write-Log ('WARNING: unexpected file signature ({0}).' -f (($signature | ForEach-Object { $_.ToString('X2') }) -join ' ')) 'Red'
}

$elapsed = $startedAt.Elapsed
$avg = if ($elapsed.TotalSeconds -gt 0) { $length / $elapsed.TotalSeconds } else { 0 }
Write-Log ('Done: {0} ({1}) in {2} at an average {3}/s' -f $OutFile, (Format-Size $length), (Format-Eta $elapsed), (Format-Size $avg)) 'Green'
