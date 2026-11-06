# AppleMusicRPC.ps1 - show what Apple Music (Windows app) is playing as Discord Rich Presence.
# Runs on built-in Windows PowerShell 5.1, no installs needed.
#   powershell.exe -ExecutionPolicy Bypass -File AppleMusicRPC.ps1

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once   # print what's playing once and exit (debug)
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------- config ----------------
$cfg = [pscustomobject]@{ clientId = ''; pollSeconds = 2; showWhenPaused = $false; smallImage = ''; showButton = $true }
if (Test-Path $ConfigPath) {
    $user = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $user.PSObject.Properties) { $cfg | Add-Member -Force NoteProperty $p.Name $p.Value }
}
if ($env:DISCORD_CLIENT_ID) { $cfg.clientId = $env:DISCORD_CLIENT_ID }
if (-not $Once -and $cfg.clientId -notmatch '^\d{15,22}$') {
    if (-not (Test-Path $ConfigPath)) { Write-Host "No config found. Copy config.example.json to config.json first." -ForegroundColor Red }
    Write-Host "Set your Discord Application ID as clientId in $ConfigPath (see README.md)." -ForegroundColor Red
    exit 1
}

function Log($msg) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) }

# ---------------- Windows media session (WinRT) ----------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
    $t = $script:asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $null = $t.Wait(5000); $t.Result
}
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$MgrT   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$PropsT = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$script:mgr = Await ($MgrT::RequestAsync()) $MgrT

function Get-NowPlaying {
    $s = $script:mgr.GetSessions() | Where-Object { $_.SourceAppUserModelId -match 'AppleMusic|iTunes' } | Select-Object -First 1
    if (-not $s) { return $null }
    $p = Await ($s.TryGetMediaPropertiesAsync()) $PropsT
    if (-not $p -or -not $p.Title) { return $null }

    # Apple Music for Windows packs "Artist <em dash> Album" into the Artist field and leaves AlbumTitle empty.
    $artist = $p.Artist; $album = $p.AlbumTitle
    $sep = " " + [char]0x2014 + " "; $i = if ($artist) { $artist.IndexOf($sep) } else { -1 }
    if (-not $album -and $i -gt 0) { $album = $artist.Substring($i + 3); $artist = $artist.Substring(0, $i) }

    $status = [string]$s.GetPlaybackInfo().PlaybackStatus
    $tl = $s.GetTimelineProperties()
    $pos = $tl.Position.TotalSeconds
    if ($status -eq 'Playing') { $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
    [pscustomobject]@{
        Title = $p.Title; Artist = $artist; Album = $album; Status = $status
        Position = [math]::Max(0, $pos); Duration = $tl.EndTime.TotalSeconds
    }
}

# ---------------- artwork / link lookup (iTunes Search API, no key) ----------------
$script:artCache = @{}
function Get-TrackInfo($np) {
    $key = "$($np.Artist)|$($np.Album)|$($np.Title)"
    if ($script:artCache.ContainsKey($key)) { return $script:artCache[$key] }
    $info = $null
    try {
        $term = [uri]::EscapeDataString("$($np.Artist) $($np.Title)")
        $r = Invoke-RestMethod "https://itunes.apple.com/search?term=$term&entity=song&limit=10" -TimeoutSec 5
        $hit = $r.results | Where-Object { $_.collectionName -eq $np.Album } | Select-Object -First 1
        if (-not $hit) { $hit = $r.results | Where-Object { $_.trackName -eq $np.Title } | Select-Object -First 1 }
        if (-not $hit) { $hit = $r.results | Select-Object -First 1 }
        if ($hit) { $info = @{ Art = ($hit.artworkUrl100 -replace '100x100bb', '512x512bb'); Url = $hit.trackViewUrl } }
    } catch { Log "Artwork lookup failed: $($_.Exception.Message)" }
    $script:artCache[$key] = $info
    $info
}

# ---------------- Discord IPC ----------------
$script:pipe = $null
function Send-Frame([int]$op, $obj) {
    $json = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $buf = [BitConverter]::GetBytes($op) + [BitConverter]::GetBytes($json.Length) + $json
    $script:pipe.Write($buf, 0, $buf.Length); $script:pipe.Flush()
}
function Read-Frame {
    $hdr = New-Object byte[] 8
    $t = $script:pipe.ReadAsync($hdr, 0, 8)
    if (-not $t.Wait(5000) -or $t.Result -lt 8) { throw 'No response from Discord' }
    $len = [BitConverter]::ToInt32($hdr, 4); $body = New-Object byte[] $len; $got = 0
    while ($got -lt $len) { $got += $script:pipe.Read($body, $got, $len - $got) }
    [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
}
function Connect-Discord {
    for ($i = 0; $i -lt 10; $i++) {
        $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', "discord-ipc-$i", [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        try { $p.Connect(300) } catch { $p.Dispose(); continue }
        $script:pipe = $p
        try {
            Send-Frame 0 @{ v = 1; client_id = [string]$cfg.clientId }
            $ready = Read-Frame
            if ($ready.evt -eq 'READY') { Log "Connected to Discord as $($ready.data.user.username)"; return $true }
            Log "Discord rejected the connection: $($ready.message)$($ready.data.message) (check clientId in config.json)"
        } catch { Log "Discord handshake failed: $($_.Exception.Message)" }
        $p.Dispose(); $script:pipe = $null
    }
    $false
}
function Set-Activity($activity) {
    Send-Frame 1 @{ cmd = 'SET_ACTIVITY'; nonce = [guid]::NewGuid().ToString(); args = @{ pid = $PID; activity = $activity } }
    $resp = Read-Frame
    if ($resp.evt -eq 'ERROR') { Log "Discord error: $($resp.data.message)" }
}

function Fit([string]$s) {   # Discord needs 2..128 chars
    if (-not $s) { return $null }
    if ($s.Length -lt 2) { $s = $s + ' ' + [char]0x200B }
    if ($s.Length -gt 128) { $s = $s.Substring(0, 127) + [char]0x2026 }
    $s
}

function Build-Activity($np) {
    $info = Get-TrackInfo $np
    $a = @{ type = 2; details = (Fit $np.Title); state = (Fit $np.Artist) }   # type 2 = "Listening to"
    $assets = @{}
    if ($info -and $info.Art) { $assets.large_image = $info.Art }
    if ($np.Album) { $assets.large_text = Fit $np.Album }
    if ($cfg.smallImage) { $assets.small_image = $cfg.smallImage; $assets.small_text = 'Apple Music' }
    if ($assets.Count) { $a.assets = $assets }
    if ($np.Status -eq 'Playing' -and $np.Duration -gt 0) {
        $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]($np.Position * 1000)
        $a.timestamps = @{ start = $start; end = $start + [long]($np.Duration * 1000) }
    } elseif ($np.Status -ne 'Playing') { $a.state = Fit "$($np.Artist) (paused)" }
    if ($cfg.showButton -and $info -and $info.Url) { $a.buttons = @(@{ label = 'Listen on Apple Music'; url = $info.Url }) }
    $a
}

# ---------------- main loop ----------------
if ($Once) { $np = Get-NowPlaying; $np | Format-List; if ($np) { Build-Activity $np | ConvertTo-Json -Depth 5 }; exit }

Log 'Apple Music -> Discord Rich Presence running. Ctrl+C to stop.'
$lastKey = $null; $lastStart = 0; $lastSent = [DateTime]::MinValue
while ($true) {
    try {
        if (-not $script:pipe -or -not $script:pipe.IsConnected) {
            if ($script:pipe) { $script:pipe.Dispose(); $script:pipe = $null; Log 'Lost connection to Discord' }
            $lastKey = $null
            if (-not (Connect-Discord)) { Start-Sleep 10; continue }
        }

        $np = Get-NowPlaying
        $show = $np -and ($np.Status -eq 'Playing' -or ($cfg.showWhenPaused -and $np.Status -eq 'Paused'))
        $key = if ($show) { "$($np.Title)|$($np.Artist)|$($np.Album)|$($np.Status)" } else { 'none' }
        $start = if ($show -and $np.Status -eq 'Playing') { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$np.Position } else { 0 }
        $seeked = [math]::Abs($start - $lastStart) -gt 3

        # Discord rate-limits SET_ACTIVITY (~5 per 20s), so only send on real changes.
        if (($key -ne $lastKey -or $seeked) -and ((Get-Date) - $lastSent).TotalSeconds -ge 4) {
            if ($show) { Set-Activity (Build-Activity $np); Log "$($np.Status): $($np.Title) - $($np.Artist)" }
            else { Set-Activity $null; Log 'Cleared presence' }
            $lastKey = $key; $lastStart = $start; $lastSent = Get-Date
        }
    } catch {
        Log "Error: $($_.Exception.Message)"
        if ($script:pipe) { $script:pipe.Dispose(); $script:pipe = $null }
    }
    Start-Sleep -Seconds $cfg.pollSeconds
}
