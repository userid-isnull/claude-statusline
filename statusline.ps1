# Claude Code status line — receives JSON on stdin, prints status lines
[CmdletBinding()]
param(
    [long]$NowEpoch = 0
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ESC = [char]0x1b
$RST = "$ESC[0m"
$BRANCH = [char]0xe0a0

# Now-epoch resolution: param overrides env var overrides system clock.
# (The env / param are for deterministic tests; production runs use the clock.)
if ($NowEpoch -gt 0) {
    $now = $NowEpoch
} elseif ($env:STATUSLINE_NOW_EPOCH) {
    $now = [long]$env:STATUSLINE_NOW_EPOCH
} else {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# --- Read JSON from stdin ---
$js = [Console]::In.ReadToEnd() | ConvertFrom-Json

$modelName = $js.model.display_name
$effortLevel = $js.effort.level
$usedPct = if ($js.context_window.used_percentage) { [math]::Floor($js.context_window.used_percentage) } else { 0 }
$ctxSize = if ($js.context_window.context_window_size) { $js.context_window.context_window_size } else { 200000 }

# Prefer the exact token count from context_window.current_usage (sum of
# input + output + cache_creation + cache_read). Falls back to the
# rounded-percentage estimate when the field is absent.
$cu = $js.context_window.current_usage
if ($cu) {
    $curTokens = 0L
    if ($cu.input_tokens)                { $curTokens += [long]$cu.input_tokens }
    if ($cu.output_tokens)               { $curTokens += [long]$cu.output_tokens }
    if ($cu.cache_creation_input_tokens) { $curTokens += [long]$cu.cache_creation_input_tokens }
    if ($cu.cache_read_input_tokens)     { $curTokens += [long]$cu.cache_read_input_tokens }
}
if (-not $curTokens) {
    $curTokens = [long][math]::Floor(($usedPct / 100.0) * $ctxSize)
}

$projDir  = $js.workspace.project_dir
$curDir   = if ($js.workspace.current_dir) { $js.workspace.current_dir } else { $js.cwd }
$sessionId = $js.session_id
$wtName   = $js.worktree.name

$rl5pct = $js.rate_limits.five_hour.used_percentage
$rl5rst = $js.rate_limits.five_hour.resets_at
$rl7pct = $js.rate_limits.seven_day.used_percentage
$rl7rst = $js.rate_limits.seven_day.resets_at

# Sonnet-only 7d (undocumented; probe two likely shapes).
$rls7pct = $null; $rls7rst = $null
if ($js.rate_limits.seven_day_sonnet) {
    $rls7pct = $js.rate_limits.seven_day_sonnet.used_percentage
    $rls7rst = $js.rate_limits.seven_day_sonnet.resets_at
} elseif ($js.rate_limits.seven_day.sonnet) {
    $rls7pct = $js.rate_limits.seven_day.sonnet.used_percentage
    $rls7rst = $js.rate_limits.seven_day.sonnet.resets_at
}

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

# Token-count danger-zone bands for the context bar (4 segments).
# < 100K: 1 segment, default; 100K-200K: 2, yellow; 200K-350K: 3, red;
# >= 350K: 4, vivid magenta.
function Get-CtxBand($tokens) {
    if ($tokens -ge 350000) { return @{ Filled = 4; Color = "$ESC[95m" } }
    if ($tokens -ge 200000) { return @{ Filled = 3; Color = "$ESC[31m" } }
    if ($tokens -ge 100000) { return @{ Filled = 2; Color = "$ESC[33m" } }
    return @{ Filled = 1; Color = '' }
}

function Render-CtxBar($filled, $color) {
    $w = 4
    $f = [math]::Min($w, [math]::Max(0, $filled))
    $fillCh  = [string][char]0x2593
    $emptyCh = [string][char]0x2591
    $filledStr = $fillCh * $f
    if ($color) { $filledStr = "$color$filledStr$RST" }
    return $filledStr + ($emptyCh * ($w - $f))
}

# 7d rate-limit bar (7 segments) — fills when pct crosses the halfway mark
# of each segment, i.e. at odd-fourteenths: 1/14, 3/14, 5/14, ..., 13/14.
# Integer arithmetic only, capped at 7.
function Get-7dFilled($pct) {
    if ($null -eq $pct) { return 0 }
    $p = [int]$pct
    if ($p -lt 0) { $p = 0 }
    if ($p -gt 100) { $p = 100 }
    $f = [int][math]::Floor((14 * $p + 100) / 200)
    if ($f -gt 7) { $f = 7 }
    if ($f -lt 0) { $f = 0 }
    return $f
}

# 7d bar render with optional green "buffer" shading on the
# (pace_filled - actual_filled) segments immediately following the
# actual-filled run.
function Render-7dBar($actualFilled, $paceFilled) {
    $w = 7
    $a = [math]::Min($w, [math]::Max(0, $actualFilled))
    $p = [math]::Min($w, [math]::Max(0, $paceFilled))
    $fillCh  = [string][char]0x2593
    $emptyCh = [string][char]0x2591
    $segs = $fillCh * $a
    if ($p -gt $a) {
        $bufN = $p - $a
        $segs += "$ESC[32m" + ($emptyCh * $bufN) + $RST
        $tailN = $w - $a - $bufN
        if ($tailN -gt 0) { $segs += $emptyCh * $tailN }
    } else {
        $tailN = $w - $a
        if ($tailN -gt 0) { $segs += $emptyCh * $tailN }
    }
    return $segs
}

# Pace = how far through the 168h window we should be by now,
# expressed as integer percent in [0,100].
function Get-Pace($resetsAt, $nowEpoch) {
    if ($null -eq $resetsAt) { return 0 }
    $hoursToReset = ($resetsAt - $nowEpoch) / 3600.0
    $pace = [int][math]::Floor(100.0 * (168.0 - $hoursToReset) / 168.0)
    if ($pace -lt 0)   { $pace = 0 }
    if ($pace -gt 100) { $pace = 100 }
    return $pace
}

# Countdown: at >= 24h, "NdMh" (whole days + remainder whole hours);
# at < 24h, "Nh" (whole hours).
function Get-Countdown($resetsAt, $nowEpoch) {
    if ($null -eq $resetsAt) { return '' }
    $secs = $resetsAt - $nowEpoch
    if ($secs -le 0) { return '(0h)' }
    $hours = [int][math]::Floor($secs / 3600.0)
    if ($hours -ge 24) {
        $days = [int][math]::Floor($hours / 24.0)
        $rem  = $hours - ($days * 24)
        return "(${days}d${rem}h)"
    } else {
        return "(${hours}h)"
    }
}

# ============================================================
# LINE 1: Model + Context + Rate Limits
# ============================================================

$band = Get-CtxBand $curTokens
$ctxBar = Render-CtxBar $band.Filled $band.Color
$line1 = "$ctxBar $usedPct% ($(Fmt-Tok $curTokens)) / $(Fmt-Tok $ctxSize)"

if ($null -ne $rl5pct -and $null -ne $rl5rst) {
    $p = [math]::Floor($rl5pct)
    $line1 += " | 5h $(Mk-Bar $p 4 25) $p% $(Epoch-Fmt $rl5rst 'HH:mm')"
}
if ($null -ne $rl7pct -and $null -ne $rl7rst) {
    $actualPct = [int][math]::Floor($rl7pct)
    $pacePct   = Get-Pace $rl7rst $now
    $aFilled   = Get-7dFilled $actualPct
    $pFilled   = Get-7dFilled $pacePct
    $bar7      = Render-7dBar $aFilled $pFilled
    $hoursToReset = ($rl7rst - $now) / 3600.0
    if ($hoursToReset -lt 24.0) {
        $rl7when = Epoch-Fmt $rl7rst 'HH:mm'
    } else {
        $rl7when = Epoch-Fmt $rl7rst 'ddd'
    }
    $countdown = Get-Countdown $rl7rst $now
    $line1 += " | 7d $bar7 $actualPct%/$pacePct% $rl7when $countdown"
}
if ($null -ne $rls7pct -and $null -ne $rls7rst) {
    $sActual = [int][math]::Floor($rls7pct)
    $sPace   = Get-Pace $rls7rst $now
    $sA      = Get-7dFilled $sActual
    $sP      = Get-7dFilled $sPace
    $sBar    = Render-7dBar $sA $sP
    $line1 += " | s7d $sBar $sActual%/$sPace%"
}

# Prepend short model name + optional effort to line 1.
# display_name like "Opus 4.7 (1M context)" → first word ("Opus"); append ":<effort>" when present.
if ($modelName) {
    $modelShort = ($modelName -split ' ')[0]
    if ($effortLevel) { $modelShort = "${modelShort}:${effortLevel}" }
    $line1 = "$modelShort $line1"
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
$gitNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$gitBranch = ''
$gitIcons = ''
$isGit = $false

if ($gitDir -and (Test-Path $gitDir -PathType Container)) {
    $needRefresh = $true

    if (Test-Path $gitCache) {
        $parts = (Get-Content $gitCache -Raw) -split "`t"
        if ($parts.Count -ge 4 -and $parts[0] -eq $gitDir -and ($gitNow - [long]$parts[3]) -le 5) {
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
            Set-Content $gitCache "$gitDir`t$gitBranch`t$gitIcons`t$gitNow" -NoNewline
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
