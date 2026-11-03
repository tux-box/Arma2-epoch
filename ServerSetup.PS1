### this file will setup a functional arma 2 dayz epoch server.
### you will need the following already installed.
# Back end Database server, mysql type.
# Visual Studio C++ Redistributables, x86 versions.
# vc2008, vc2010, vc2012, vc2013, vc2015, vc2017
# steam account, steamcmd is supported
# 7zip
#
# If a download cannot be automated, the link is opened in your default browser.
#
# Github link for server download https://github.com/EpochModTeam/DayZ-Epoch.git
#
#
# Find first unused drive letter (D-Z)
$used = Get-Volume | Select-Object -ExpandProperty DriveLetter
$drive = $null
for ($i = [char]'D'; $i -le [char]'Z'; $i++) {
    $letter = [string]$i
    if ($letter -notin $used) {
        $drive = $letter
        break
    }
}

if (-not $drive) {
    Write-Error "No unused drive letters found"
    exit 1
}

# Get the folder the script's directory from
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Map the folder to the drive
subst "${drive}:" "$scriptDir"

Write-Host "Mapped ${drive}: to $scriptDir"

#Prestage, complete. Downloading files

$epochClientFiles="https://drive.usercontent.google.com/download?id=19iCJevU008g311vsxJNR0PjYmkSv36YK&export=download&authuser=0&confirm=t&uuid=f9ff194b-1730-46cd-99b7-ab37067a23ec&at=AMrWOn2KicdgFMs0Czlvh5KfjhKj%3A1793582616560"
$epochServerFiles="https://drive.usercontent.google.com/download?id=1jDn86sfTwcRae4NZgHK76k_CaY1jOUP2&export=download&authuser=0&confirm=t&uuid=a55bb189-6b33-4d20-b6e2-ff1cff74aa17&at=AMrWOn3pBd9k4YR1R0L3JSXkrF5e%3A1793582631324"

# Google Drive download helper function
# Streams straight to disk (these archives are 4+ GB, so nothing is held in memory),
# resumes from a .part file with HTTP Range requests, retries dropped or stalled
# connections with exponential backoff, then verifies the size and 7-Zip signature.

function Format-DriveSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-DriveEta {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 0 -or [double]::IsInfinity($Span.TotalSeconds)) { return '--:--:--' }
    return ('{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
}

function Write-DriveLog {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

# Pull the file id out of a usercontent/share URL so a dead link can be re-resolved.
function Get-DriveFileId {
    param([string]$Url)
    foreach ($pattern in @('(?:[?&](?:id|id%3D))=?([A-Za-z0-9_-]{10,})', '/file/d/([A-Za-z0-9_-]{10,})', '/d/([A-Za-z0-9_-]{10,})')) {
        $m = [regex]::Match($Url, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# Pull the real download URL out of Drive's "can't scan this file for viruses" page.
function Get-DriveConfirmUrl {
    param([string]$Html, [string]$BaseUrl)

    $form = [regex]::Match($Html, '(?is)<form[^>]*action\s*=\s*"([^"]+)"[^>]*>(.*?)</form>')
    if ($form.Success) {
        $action = [System.Net.WebUtility]::HtmlDecode($form.Groups[1].Value)
        try { $action = (New-Object System.Uri((New-Object System.Uri($BaseUrl)), $action)).AbsoluteUri } catch { }

        $pairs = New-Object System.Collections.Generic.List[string]
        foreach ($input in [regex]::Matches($form.Groups[2].Value, '(?is)<input[^>]*>')) {
            $name  = [regex]::Match($input.Value, '(?i)name\s*=\s*"([^"]*)"' ).Groups[1].Value
            $value = [regex]::Match($input.Value, '(?i)value\s*=\s*"([^"]*)"' ).Groups[1].Value
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
function Resolve-DriveUrl {
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
                $next = Get-DriveConfirmUrl -Html $html -BaseUrl $url
                if (-not $next) {
                    $title = [regex]::Match($html, '(?is)<title>(.*?)</title>').Groups[1].Value.Trim()
                    $detail = if ($title) { " ('$title')" } else { '' }
                    throw "Google Drive returned an HTML page instead of the file$detail. The link may have expired or hit its download quota."
                }
                Write-DriveLog 'Drive confirm page returned - following the real download link.' 'Yellow'
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
function Get-DriveRemoteInfo {
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
        if ($cd -and $cd.FileName) { $name = [System.IO.Path]::GetFileName($cd.FileName.Trim('\"')) }

        return [pscustomobject]@{ Url = $Url; Length = $length; FileName = $name }
    }
    finally {
        $response.Dispose()
        $request.Dispose()
    }
}

# Streamed, resumable transfer of the body into the .part file.
function Invoke-DriveDownload {
    param($Client, [string]$Url, [string]$TargetPath, [long]$TotalLength, [int]$MaxRetries, [int]$StallTimeoutSeconds)

    $partPath = "$TargetPath.part"
    $buffer   = New-Object byte[] (1MB)
    $attempt  = 0

    while ($true) {
        $attempt++
        $have = 0L
        if (Test-Path -LiteralPath $partPath) { $have = (Get-Item -LiteralPath $partPath).Length }
        if ($TotalLength -gt 0 -and $have -ge $TotalLength) { return $partPath }

        try {
            if ($have -gt 0) { Write-DriveLog ('Resuming at {0} ({1})' -f (Format-DriveSize $have), "attempt $attempt") 'Yellow' }

            $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $url
            if ($have -gt 0) { [void]$request.Headers.TryAddWithoutValidation('Range', "bytes=$have-") }

            $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

            if ($response.StatusCode -eq [System.Net.HttpStatusCode]::OK -and $have -gt 0) {
                Write-DriveLog 'Server ignored the resume request - restarting from 0.' 'Yellow'
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
                            Write-DriveLog ('{0,5:N1}%  {1} / {2}  {3}/s  ETA {4}' -f $pct, (Format-DriveSize $have), (Format-DriveSize $TotalLength), (Format-DriveSize $speed), (Format-DriveEta $eta))
                            if ($Host.Name -eq 'ConsoleHost') {
                                Write-Progress -Activity "Downloading $(Split-Path -Leaf $TargetPath)" `
                                    -Status ('{0} / {1}' -f (Format-DriveSize $have), (Format-DriveSize $TotalLength)) `
                                    -PercentComplete ([int][Math]::Min(100, $pct)) -SecondsRemaining ([int][Math]::Max(0, $eta.TotalSeconds))
                            }
                        }
                        else {
                            Write-DriveLog ('{0} downloaded  {1}/s' -f (Format-DriveSize $have), (Format-DriveSize $speed))
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
                if ($Host.Name -eq 'ConsoleHost') { Write-Progress -Activity "Downloading $(Split-Path -Leaf $TargetPath)" -Completed }
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
            Write-DriveLog "Attempt $attempt failed: $message" 'Red'
            Write-DriveLog "Retrying in $wait s (the .part file is kept, so nothing restarts from zero)." 'Yellow'
            Start-Sleep -Seconds $wait
        }
    }
}

# Last resort when the automated transfer cannot finish: hand the link to the system
# default browser, then verify whatever the user saved by hand.
function Invoke-DriveBrowserFallback {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$RemoteName,

        [long]$TotalLength = 0,

        [switch]$NonInteractive
    )

    Write-Host ''
    Write-DriveLog 'Automated download failed - falling back to the default web browser.' 'Yellow'
    Write-DriveLog "Link: $Url" 'Cyan'

    try {
        Start-Process -FilePath $Url
        Write-DriveLog 'Default browser launched with the download link.' 'Yellow'
    }
    catch {
        Write-DriveLog "Could not launch a browser automatically ($($_.Exception.Message))." 'Red'
        Write-DriveLog 'Open the link above by hand instead.' 'Yellow'
    }

    Write-Host ''
    Write-Host 'Save the archive as:' -ForegroundColor Yellow
    Write-Host "  $OutputPath" -ForegroundColor Yellow
    if ($RemoteName) {
        Write-Host ("  (the browser will name it {0}; leaving it in your Downloads folder is fine)" -f $RemoteName) -ForegroundColor DarkGray
    }
    Write-Host ''

    if ($NonInteractive) {
        throw "Automated download failed. Open the link above, save it as $OutputPath, then run this script again."
    }

    [void](Read-Host 'Press Enter once the archive has finished downloading')

    # Where the browser would have put it, then where the script expects it.
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($OutputPath)
    if ($RemoteName) {
        $candidates.Add((Join-Path (Join-Path $env:USERPROFILE 'Downloads') $RemoteName))
    }

    $found = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $candidate
        if ($item.Length -le 1MB) {
            Write-DriveLog ("Ignoring {0} - only {1:N0} bytes." -f $candidate, $item.Length) 'Yellow'
            continue
        }
        if ($TotalLength -gt 0 -and $item.Length -ne $TotalLength) {
            Write-DriveLog ("Ignoring {0} - {1:N0} bytes but expected {2:N0}." -f $candidate, $item.Length, $TotalLength) 'Yellow'
            continue
        }
        $found = $item
        break
    }

    if (-not $found) {
        $where = if ($RemoteName) { " or $RemoteName in $env:USERPROFILE\Downloads" } else { '' }
        throw "No completed archive found. Expected $OutputPath$where, then run this script again."
    }

    # Compare resolved full paths, so a short 8.3 path is not mistaken for another file.
    $alreadyInPlace = (Test-Path -LiteralPath $OutputPath) -and
        ((Get-Item -LiteralPath $OutputPath).FullName -eq $found.FullName)

    if (-not $alreadyInPlace) {
        Write-DriveLog ("Moving {0} into place." -f $found.FullName) 'Cyan'
        Move-Item -LiteralPath $found.FullName -Destination $OutputPath -Force
    }

    # Drop the .part left behind by the failed automated attempt.
    $partPath = "$OutputPath.part"
    if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }

    # Same 7-Zip signature check the automated path performs.
    $signature = New-Object byte[] 6
    $reader = [System.IO.File]::OpenRead($OutputPath)
    try { [void]$reader.Read($signature, 0, 6) } finally { $reader.Dispose() }

    if ($signature[0] -eq 0x37 -and $signature[1] -eq 0x7A -and $signature[2] -eq 0xBC -and
        $signature[3] -eq 0xAF -and $signature[4] -eq 0x27 -and $signature[5] -eq 0x1C) {
        $size = (Get-Item -LiteralPath $OutputPath).Length
        Write-DriveLog ('Verified: valid 7-Zip archive ({0}).' -f (Format-DriveSize $size)) 'Green'
        return
    }

    throw "The saved file is not a 7-Zip archive - the browser probably saved an HTML page instead. Delete $OutputPath and open the link again."
}

function Get-GoogleDriveFile {
    param(
        [Parameter(Mandatory, ParameterSetName = 'Url')]
        [string]$Url,

        # Skip the browser fallback and just fail, for unattended runs.
        [switch]$NoBrowserFallback,

        [Parameter(Mandatory, ParameterSetName = 'Id')]
        [string]$FileId,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [int]$MaxRetries = 6,

        [int]$StallTimeoutSeconds = 120
    )

    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        $Url = "https://drive.google.com/uc?export=download&id=$FileId"
    }

    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $startedAt = [System.Diagnostics.Stopwatch]::StartNew()
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.UseCookies = $true
    $handler.CookieContainer = New-Object System.Net.CookieContainer
    $handler.MaxConnectionsPerServer = 1

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')

    try {
        # Try the link as given, then the plain uc?export=download form (fresh token).
        $candidates = New-Object System.Collections.Generic.List[string]
        $candidates.Add($Url)
        $id = Get-DriveFileId $Url
        if ($id) { $candidates.Add("https://drive.google.com/uc?export=download&id=$id") }

        $plan = $null
        foreach ($candidate in $candidates) {
            try {
                $finalUrl = Resolve-DriveUrl -Client $client -StartUrl $candidate
                $plan = Get-DriveRemoteInfo -Client $client -Url $finalUrl
                break
            }
            catch {
                Write-DriveLog "Link rejected: $($_.Exception.Message)" 'Red'
            }
        }
        if (-not $plan) { throw "Could not resolve a working download link for $Url" }

        Write-DriveLog "Downloading from Google Drive..." 'Cyan'
        Write-DriveLog "Target     : $OutputPath" 'Cyan'
        if ($plan.Length -gt 0) {
            Write-DriveLog ('Size       : {0} ({1:N0} bytes)' -f (Format-DriveSize $plan.Length), $plan.Length) 'Cyan'
        }
        Write-DriveLog 'Resume     : enabled (.part file)' 'Cyan'

        if ((Test-Path -LiteralPath $OutputPath) -and $plan.Length -gt 0 -and
            (Get-Item -LiteralPath $OutputPath).Length -eq $plan.Length) {
            Write-DriveLog 'File is already fully downloaded - nothing to do.' 'Green'
            return
        }

        # Refuse to start a multi-gigabyte transfer that cannot fit where it is going.
        try {
            $root = [System.IO.Path]::GetPathRoot($OutputPath)
            $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
            if ($plan.Length -gt 0 -and $free -lt $plan.Length) {
                throw ('Not enough free space on {0}: need {1}, only {2} available.' -f `
                    $root, (Format-DriveSize $plan.Length), (Format-DriveSize $free))
            }
        }
        catch [System.ArgumentException] { }

        $partPath = Invoke-DriveDownload -Client $client -Url $plan.Url -TargetPath $OutputPath `
            -TotalLength $plan.Length -MaxRetries $MaxRetries -StallTimeoutSeconds $StallTimeoutSeconds

        $length = (Get-Item -LiteralPath $partPath).Length
        if ($plan.Length -gt 0 -and $length -ne $plan.Length) {
            throw "Downloaded $length bytes but expected $($plan.Length)."
        }

        Move-Item -LiteralPath $partPath -Destination $OutputPath -Force

        # 7-Zip archives start with "7z" + BC AF 27 1C; anything else means a page was saved.
        $signature = New-Object byte[] 6
        $reader = [System.IO.File]::OpenRead($OutputPath)
        try { [void]$reader.Read($signature, 0, 6) } finally { $reader.Dispose() }

        if ($signature[0] -eq 0x37 -and $signature[1] -eq 0x7A -and $signature[2] -eq 0xBC -and
            $signature[3] -eq 0xAF -and $signature[4] -eq 0x27 -and $signature[5] -eq 0x1C) {
            $elapsed = $startedAt.Elapsed
            $avg = if ($elapsed.TotalSeconds -gt 0) { $length / $elapsed.TotalSeconds } else { 0 }
            Write-DriveLog ('Verified: valid 7-Zip archive, {0} in {1} at an average {2}/s' -f `
                (Format-DriveSize $length), (Format-DriveEta $elapsed), (Format-DriveSize $avg)) 'Green'
        }
        elseif ($signature[0] -eq 0x3C) {
            Write-DriveLog 'WARNING: the file looks like HTML, not a 7z archive. The link probably expired.' 'Red'
        }
        else {
            Write-DriveLog ('WARNING: unexpected file signature ({0}).' -f (($signature | ForEach-Object { $_.ToString('X2') }) -join ' ')) 'Red'
        }
    }
    catch {
        if ($NoBrowserFallback) { throw }

        Write-DriveLog "Download failed: $($_.Exception.Message)" 'Red'

        $remoteName = if ($plan -and $plan.FileName) { $plan.FileName } else { Split-Path -Leaf $OutputPath }
        $expected   = if ($plan) { [long]$plan.Length } else { 0L }
        $unattended = ($Host.Name -ne 'ConsoleHost') -or [Console]::IsInputRedirected

        Invoke-DriveBrowserFallback -Url $Url -OutputPath $OutputPath -RemoteName $remoteName `
            -TotalLength $expected -NonInteractive:$unattended
    }
    finally {
        $client.Dispose()
    }
}

# Download server files ($epochServerFiles URL set above)
$serverArchive = "${drive}:\epoch_server_files.7z"
if (-not (Test-Path $serverArchive) -or (Get-Item $serverArchive).Length -lt 1MB) {
    Get-GoogleDriveFile -Url $epochServerFiles -OutputPath $serverArchive
}
else {
    Write-Host "Server archive already downloaded."
}

# Download client files ($epochClientFiles URL set above)
$clientArchive = "${drive}:\epoch_client_files.7z"
if (-not (Test-Path $clientArchive) -or (Get-Item $clientArchive).Length -lt 1MB) {
    Get-GoogleDriveFile -Url $epochClientFiles -OutputPath $clientArchive
}
else {
    Write-Host "Client archive already downloaded."
}

# Extract server files if the extracted folder doesn't exist
if (-not (Test-Path "${drive}:\@DayZ_Epoch")) {
    Write-Host "Extracting server files..."
    & "C:\Program Files\7-Zip\7z.exe" x "$serverArchive" "-p123456" "-o${drive}:\"
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip extraction failed with exit code $LASTEXITCODE"
    }
    Write-Host "Server files extracted."
} else {
    Write-Host "Server files already extracted."
}

# Extract client files if the extracted folder doesn't exist
if (-not (Test-Path "${drive}:\epoch_client_files")) {
    Write-Host "Extracting client files..."
    & "C:\Program Files\7-Zip\7z.exe" x "$clientArchive" "-o${drive}:\"
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip extraction failed with exit code $LASTEXITCODE"
    }
    Write-Host "Client files extracted."
} else {
    Write-Host "Client files already extracted."
}

# Unblock files
Write-Host "Unblocking downloaded files..."
Get-ChildItem "${drive}:\*.7z" -Recurse | Unblock-File
Write-Host "Done."

# -----------------------------------------------------------
# File copy operations
# -----------------------------------------------------------
Write-Host ""
Write-Host "Copying files to target directory..."
Write-Host ""

# Copy D:\@DayZ_Epoch to D:\a2
$sourceEpoch = "${drive}:\"
$targetA2 = "${drive}:\a2"
if (Test-Path $sourceEpoch) {
    Write-Host "Copying @DayZ_Epoch to $targetA2..."
    Copy-Item -Path "$sourceEpoch\@DayZ_Epoch" -Destination $targetA2 -Recurse -Force
    Write-Host "Done."
} else {
    Write-Host "WARNING: Source not found: $sourceEpoch" -ForegroundColor Yellow
}

# Copy @DayZ_Epoch_Server, dlls, DZE_Server_Config, Keys, MPMissions from Server Files folder
$serverSource = "${drive}:\Epoch1071_Server_Files_PW_123456\Server Files"
$foldersToCopy = @("@DayZ_Epoch_Server", "dlls", "DZE_Server_Config", "Keys", "MPMissions")
foreach ($folder in $foldersToCopy) {
    $src = Join-Path $serverSource $folder
    if (Test-Path $src) {
        Write-Host "Copying $folder to $targetA2..."
        Copy-Item -Path $src -Destination $targetA2 -Recurse -Force
        Write-Host "Done."
    } else {
        Write-Host "WARNING: Source not found: $src" -ForegroundColor Yellow
    }
}

# Copy DLLs from dlls subfolder to root
$dllSource = "${targetA2}\dlls"
if (Test-Path $dllSource) {
    Write-Host "Copying DLLs to $targetA2..."
    Copy-Item -Path "$dllSource\DatabaseMySql.dll", "$dllSource\HiveExt.dll", "$dllSource\tbb.dll", "$dllSource\tbbmalloc.dll" -Destination $targetA2 -Force
    Write-Host "Done."
}

# Copy bikey files from "External Keys" to Keys folder
$externalKeys = "${targetA2}\Keys\External Keys (use as needed)"
$targetKeys = "${targetA2}\Keys"
if (Test-Path $externalKeys) {
    Write-Host "Copying bikey files from External Keys to Keys folder..."
    Get-ChildItem -Path $externalKeys -Filter "*.bikey" | ForEach-Object {
        $dest = Join-Path $targetKeys $_.Name
        if (-not (Test-Path $dest)) {
            Copy-Item -Path $_.FullName -Destination $dest -Force
            Write-Host "Copied: $($_.Name)"
        } else {
            Write-Host "Skipped (exists): $($_.Name)" -ForegroundColor Yellow
        }
    }
    Write-Host "Done."
}

# Copy bat files from DZE_Server_Config to root
$batSource = "${targetA2}\DZE_Server_Config"
if (Test-Path $batSource) {
    Write-Host "Copying bat files to $targetA2..."
    Get-ChildItem -Path $batSource -Filter "*.bat" | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $targetA2 -Force
        Write-Host "Copied: $($_.Name)"
    }
    Write-Host "Done."
}

# Update bat files to use correct paths
Write-Host ""
Write-Host "Updating bat files with correct paths..."
$batFiles = Get-ChildItem -Path $targetA2 -Filter "*.bat" -Recurse
foreach ($batFile in $batFiles) {
    $content = Get-Content -Path $batFile.FullName -Raw
    # Replace C:\DZE_Server_Config and ${drive}:\DZE_Server_Config with the actual target drive
    $oldPaths = @("C:\DZE_Server_Config", "${drive}:\DZE_Server_Config")
    $newPath = "${targetA2}\DZE_Server_Config"
    
    $modified = $false
    foreach ($oldPath in $oldPaths) {
        if ($content -match [regex]::Escape($oldPath)) {
            $content = $content -replace [regex]::Escape($oldPath), $newPath
            $modified = $true
            Write-Host "Updated: $($batFile.Name) - replaced '$oldPath'"
        }
    }
    
    if ($modified) {
        $content | Set-Content -Path $batFile.FullName -NoNewline
        Write-Host "  -> now using: $newPath" -ForegroundColor Green
    }
}
Write-Host "Bat file updates complete."

Write-Host ""
Write-Host "Setup complete!"
Write-Host "Server files location: ${drive}:\a2"
Write-Host "Server config: ${drive}:\a2\DZE_Server_Config"
