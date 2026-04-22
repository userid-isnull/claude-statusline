# Claude Code status line — receives JSON on stdin, prints status lines
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ESC = [char]0x1b
$RST = "$ESC[0m"
$BRANCH = [char]0xe0a0

# --- Read JSON from stdin ---
$js = [Console]::In.ReadToEnd() | ConvertFrom-Json

$usedPct = if ($js.context_window.used_percentage) { [math]::Floor($js.context_window.used_percentage) } else { 0 }
$ctxSize = if ($js.context_window.context_window_size) { $js.context_window.context_window_size } else { 200000 }
$inTok  = if ($js.context_window.total_input_tokens) { $js.context_window.total_input_tokens } else { 0 }
$outTok = if ($js.context_window.total_output_tokens) { $js.context_window.total_output_tokens } else { 0 }

$projDir  = $js.workspace.project_dir
$curDir   = if ($js.workspace.current_dir) { $js.workspace.current_dir } else { $js.cwd }
$sessionId = $js.session_id
$wtName   = $js.worktree.name

$rl5pct = $js.rate_limits.five_hour.used_percentage
$rl5rst = $js.rate_limits.five_hour.resets_at
$rl7pct = $js.rate_limits.seven_day.used_percentage
$rl7rst = $js.rate_limits.seven_day.resets_at
$rlSpct = $js.rate_limits.seven_day_sonnet.used_percentage
$rlSrst = $js.rate_limits.seven_day_sonnet.resets_at

# --- Helpers ---

function Fmt-Tok($n) {
    if ($n -ge 1000000) {
        $m = [math]::Floor($n / 100000)
        "$([math]::Floor($m / 10)).$($m % 10)M"
    } elseif ($n -ge 1000) {
        "$([math]::Floor($n / 1000))K"
    } else { "$n" }
}

function Mk-Bar($pct, $w, $d) {
    if ($null -eq $pct) { $pct = 0 }
    $f = [math]::Min($w, [math]::Max(0, [math]::Floor(($pct + $d / 2) / $d)))
    ([string][char]0x2593 * $f) + ([string][char]0x2591 * ($w - $f))
}

function Epoch-Fmt($epoch, $fmt) {
    try { [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).LocalDateTime.ToString($fmt) }
    catch { '???' }
}

# ============================================================
# LINE 1: Context + Rate Limits (no color)
# ============================================================

$ctxBar = Mk-Bar $usedPct 10 10
$line1 = "$ctxBar $usedPct% / $(Fmt-Tok $ctxSize) | $([char]0x2191)$(Fmt-Tok $inTok) $([char]0x2193)$(Fmt-Tok $outTok)"

if ($null -ne $rl5pct -and $null -ne $rl5rst) {
    $p = [math]::Floor($rl5pct)
    $line1 += " | 5h $(Mk-Bar $p 4 25) $p% $(Epoch-Fmt $rl5rst 'HH:mm')"
}
if ($null -ne $rl7pct -and $null -ne $rl7rst) {
    $p = [math]::Floor($rl7pct)
    $resetDt = [DateTimeOffset]::FromUnixTimeSeconds([long]$rl7rst).LocalDateTime
    $rl7when = if ($resetDt.Date -eq [DateTime]::Today) { $resetDt.ToString('HH:mm') } else { $resetDt.ToString('ddd') }
    $line1 += " | 7d $(Mk-Bar $p 4 25) $p% $rl7when"
}
if ($null -ne $rlSpct -and $null -ne $rlSrst) {
    $p = [math]::Floor($rlSpct)
    $resetDt = [DateTimeOffset]::FromUnixTimeSeconds([long]$rlSrst).LocalDateTime
    $rlSwhen = if ($resetDt.Date -eq [DateTime]::Today) { $resetDt.ToString('HH:mm') } else { $resetDt.ToString('ddd') }
    $line1 += " | 7dS $(Mk-Bar $p 4 25) $p% $rlSwhen"
}


[Console]::Out.Write("${line1}`n")

# ============================================================
# LINE 2: Workspace (starship-style) + Session ID
# ============================================================

# --- SSH host detection + starship palette color ---
$hostPrefix = ''
$hostPrefixLen = 0

if ($env:SSH_CONNECTION) {
    $sshUser = $env:USERNAME
    $sshHost = $env:COMPUTERNAME.ToLower()
    $hostText = " $sshUser@$sshHost "
    $hostPrefixLen = $hostText.Length + 1

    $scfg = if ($env:STARSHIP_CONFIG) { $env:STARSHIP_CONFIG } else { "$env:USERPROFILE\.config\starship.toml" }
    if (Test-Path $scfg) {
        $raw = Get-Content $scfg -Raw
        if ($raw -match '(?m)^palette\s*=\s*"([^"]+)"') {
            $pal = $Matches[1]
            if ($raw -match "(?s)\[palettes\.$pal\][^\[]*?color1\s*=\s*`"#?([0-9a-fA-F]{6})`"") {
                $h = $Matches[1]
                $r = [Convert]::ToInt32($h.Substring(0,2), 16)
                $g = [Convert]::ToInt32($h.Substring(2,2), 16)
                $b = [Convert]::ToInt32($h.Substring(4,2), 16)
                $hostPrefix = "$ESC[1;7;38;2;${r};${g};${b}m${hostText}${RST} "
            }
        }
    }
    if (-not $hostPrefix) {
        $hostPrefix = "$sshUser@$sshHost "
        $hostPrefixLen = $hostPrefix.Length
    }
}

# --- Git status (cached) ---
$gitDir = if ($curDir) { $curDir } else { $projDir }
$gitCache = Join-Path $env:TEMP 'claude-sl-git.txt'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$gitBranch = ''
$gitIcons = ''
$isGit = $false

if ($gitDir -and (Test-Path $gitDir -PathType Container)) {
    $needRefresh = $true

    if (Test-Path $gitCache) {
        $parts = (Get-Content $gitCache -Raw) -split "`t"
        if ($parts.Count -ge 4 -and $parts[0] -eq $gitDir -and ($now - [long]$parts[3]) -le 5) {
            $gitBranch = $parts[1]
            $gitIcons = $parts[2]
            $isGit = $true
            $needRefresh = $false
        }
    }

    if ($needRefresh) {
        $null = git -C $gitDir rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -eq 0) {
            $isGit = $true
            $gitBranch = git -C $gitDir branch --show-current 2>$null
            $ic = ''
            if (git -C $gitDir diff --cached --numstat 2>$null | Select-Object -First 1) { $ic += '+' }
            if (git -C $gitDir diff --numstat 2>$null | Select-Object -First 1) { $ic += '!' }
            if (git -C $gitDir ls-files --others --exclude-standard 2>$null | Select-Object -First 1) { $ic += '?' }
            $gitIcons = $ic
            Set-Content $gitCache "$gitDir`t$gitBranch`t$gitIcons`t$now" -NoNewline
        }
    }
}

# --- Build workspace string ---
$wsPart = ''

if ($isGit) {
    $wsPart = Split-Path $projDir -Leaf
    $bd = if ($wtName) { $wtName } else { $gitBranch }
    if ($bd) { $wsPart += " $BRANCH $bd" }
    if ($gitIcons) { $wsPart += " [$gitIcons]" }
} else {
    $home_ = $env:USERPROFILE -replace '\\','/'
    $pd = "$projDir" -replace '\\','/'
    if ($pd -and $pd.StartsWith($home_, [StringComparison]::OrdinalIgnoreCase)) {
        $wsPart = '~' + $pd.Substring($home_.Length)
    } else { $wsPart = $projDir }
}

# Working directory if different
$cd = "$curDir" -replace '\\','/'; $pd2 = "$projDir" -replace '\\','/'
if ($cd -and $cd -ne $pd2) {
    if ($cd.StartsWith("$pd2/")) { $rel = $cd.Substring($pd2.Length + 1) }
    else { $rel = Split-Path $curDir -Leaf }
    $wsPart += " > ./$rel"
}

$sidPart = "| $sessionId"

# --- Width check (90 char limit) and output ---
$totalLen = $hostPrefixLen + $wsPart.Length + 1 + $sidPart.Length

if ($totalLen -le 90) {
    [Console]::Out.Write("${hostPrefix}${wsPart} ${sidPart}")
} else {
    [Console]::Out.Write("${hostPrefix}${wsPart}`n")
    [Console]::Out.Write($sidPart)
}
