param([switch]$NoWindow)   # -NoWindow: serve only (for testing)
$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$port  = 48721
$token = [guid]::NewGuid().ToString('N')   # page-only secret so other sites can't POST to us
$dl    = Join-Path $env:USERPROFILE 'Downloads'
$ver   = (Get-Content "$root\package.json" -Raw | ConvertFrom-Json).version

$pk    = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
$ytDir = Get-ChildItem "$pk\yt-dlp.yt-dlp*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$ffDir = Get-ChildItem "$pk\Gyan.FFmpeg*\ffmpeg-*\bin" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$yt    = if ($ytDir) { Join-Path $ytDir.FullName 'yt-dlp.exe' }
if ($yt) { Start-Process $yt '-U' -WindowStyle Hidden }   # ponytail: may race a very early download; fine

$script:p = $null; $script:mp3 = $false; $script:log = "$env:TEMP\moonlit-out.log"; $script:err = "$env:TEMP\moonlit-err.log"

function ReadLog($f) {
    if (-not (Test-Path $f)) { return '' }
    $s = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($s)).ReadToEnd() } finally { $s.Close() }
}

function Get-State {
    if (-not $script:p) { return @{ phase = 'idle' } }
    $out = ReadLog $script:log
    $m = [regex]::Matches($out, 'PCT\s+([\d.]+)%')
    $pct = if ($m.Count) { [double]$m[$m.Count - 1].Groups[1].Value } else { 0 }
    $n = [Math]::Max(1, [regex]::Matches($out, 'Destination:').Count)
    $total = if ($script:mp3) { 1 } else { 2 }          # video + audio streams
    $overall = [Math]::Min(99, (($n - 1) * 100 + $pct) / $total)
    if (-not $script:p.HasExited) {
        $phase = if ($out -match '\[(Merger|ExtractAudio)\]') { 'finishing' } else { 'downloading' }
        return @{ phase = $phase; pct = [Math]::Round($overall) }
    }
    if ($script:p.ExitCode -eq 0) {
        $f = [regex]::Matches($out, '(?m)(?:Destination: |into ")(.+?)"?\r?$')
        $name = if ($f.Count) { Split-Path -Leaf $f[$f.Count - 1].Groups[1].Value } else { '' }
        return @{ phase = 'done'; pct = 100; file = $name }
    }
    $e = [regex]::Matches((ReadLog $script:err), '(?m)ERROR:.*')
    $msg = if ($e.Count) { $e[$e.Count - 1].Value.Trim() } else { 'Download failed.' }
    return @{ phase = 'error'; msg = $msg }
}

function Send($rs, $obj, $code = 200) {
    $b = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    $rs.StatusCode = $code; $rs.ContentType = 'application/json; charset=utf-8'
    $rs.OutputStream.Write($b, 0, $b.Length); $rs.Close()
}

trap { "$(Get-Date) $_" | Out-File "$env:TEMP\moonlit-error.log" -Append; exit 1 }

function Open-Window {
    $b = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
           "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
           "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $b) { throw 'Neither Edge nor Chrome found.' }   # ponytail: no other-browser fallback
    Start-Process $b "--app=http://127.0.0.1:$port/ --window-size=1080,700 --user-data-dir=`"$env:TEMP\moonlit-profile`""
}

$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:$port/")
try { $l.Start() } catch { Open-Window; exit }   # server already running: just open another window on it
if (-not $NoWindow) { Open-Window }

$last = Get-Date; $seen = $false
:outer while ($true) {
    $t = $l.GetContextAsync()
    while (-not $t.Wait(1000)) {
        # window closed; generous because browsers throttle timers in minimized windows to ~1/min
        if ($seen -and ((Get-Date) - $last).TotalSeconds -gt 150) { break outer }
    }
    $c = $t.Result; $rq = $c.Request; $rs = $c.Response
    try {
        $path = $rq.Url.AbsolutePath
        if ($path -eq '/') {
            $html = [IO.File]::ReadAllText("$root\index.html").Replace('__TOKEN__', $token).Replace('__VERSION__', $ver)
            $b = [Text.Encoding]::UTF8.GetBytes($html)
            $rs.ContentType = 'text/html; charset=utf-8'; $rs.OutputStream.Write($b, 0, $b.Length); $rs.Close()
        }
        elseif ($rq.Headers['X-Token'] -ne $token) { Send $rs @{ error = 'forbidden' } 403 }
        elseif ($path -eq '/status') {
            $last = Get-Date; $seen = $true
            Send $rs (Get-State)
        }
        elseif ($path -eq '/open') { Start-Process explorer.exe $dl; Send $rs @{ ok = $true } }
        elseif ($path -eq '/download') {
            $req = (New-Object IO.StreamReader($rq.InputStream)).ReadToEnd() | ConvertFrom-Json
            $busy = $script:p -and -not $script:p.HasExited
            if (-not $yt -or -not $ffDir) { Send $rs @{ error = 'yt-dlp or ffmpeg is not installed.' } 400 }
            elseif ($busy) { Send $rs @{ error = 'A download is already running.' } 409 }
            elseif ($req.url -notmatch '^https?://(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/[^\s"'']+$') { Send $rs @{ error = 'That does not look like a YouTube link.' } 400 }
            elseif ($req.quality -notmatch '^(mp3|720|1080|1440|2160)$') { Send $rs @{ error = 'Bad quality.' } 400 }
            else {
                $q = $req.quality
                $script:mp3 = ($q -eq 'mp3')
                $a = @('--newline', '--no-playlist', '--progress-template', 'download:PCT %(progress._percent_str)s',
                       '--ffmpeg-location', $ffDir.FullName, '-P', $dl, '-o', '%(title)s.%(ext)s')
                if ($script:mp3) { $a += @('-x', '--audio-format', 'mp3', '--audio-quality', '0') }
                else { $a += @('-f', "bv*[height<=$q]+ba/b[height<=$q]/bv*+ba/b", '--merge-output-format', 'mp4') }
                $a += @('--', $req.url)
                $argStr = ($a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
                $script:p = Start-Process $yt $argStr -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput $script:log -RedirectStandardError $script:err
                $null = $script:p.Handle   # cache handle so ExitCode works
                Send $rs @{ ok = $true }
            }
        }
        else { Send $rs @{ error = 'not found' } 404 }
    } catch {
        try { Send $rs @{ error = "$_" } 500 } catch {}
    }
}
$l.Stop()
