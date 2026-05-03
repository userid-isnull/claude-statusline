# Test helpers for statusline.ps1 Pester suite.
# Loaded via dot-sourcing in BeforeAll of each test file.

$script:StatuslinePath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'statusline.ps1')).Path

function New-StatuslinePayload {
    param(
        [int]$UsedPct = 5,
        [long]$CtxSize = 1000000,
        [long]$InTokens = 0,
        [long]$OutTokens = 0,
        [string]$SessionId = 'test-session',
        [string]$ProjectDir = 'C:/tmp/proj',
        [string]$CurrentDir,
        [hashtable]$CurrentUsage,
        [Nullable[double]]$Rl5Pct,
        [Nullable[long]]$Rl5ResetsAt,
        [Nullable[double]]$Rl7Pct,
        [Nullable[long]]$Rl7ResetsAt
    )
    $payload = @{
        context_window = @{
            used_percentage      = $UsedPct
            context_window_size  = $CtxSize
            total_input_tokens   = $InTokens
            total_output_tokens  = $OutTokens
        }
        session_id = $SessionId
        workspace  = @{ project_dir = $ProjectDir }
    }
    if ($CurrentUsage) { $payload.context_window.current_usage = $CurrentUsage }
    if ($PSBoundParameters.ContainsKey('CurrentDir')) {
        $payload.workspace.current_dir = $CurrentDir
    }
    $rateLimits = @{}
    if ($null -ne $Rl5Pct -and $null -ne $Rl5ResetsAt) {
        $rateLimits.five_hour = @{ used_percentage = $Rl5Pct; resets_at = $Rl5ResetsAt }
    }
    if ($null -ne $Rl7Pct -and $null -ne $Rl7ResetsAt) {
        $rateLimits.seven_day = @{ used_percentage = $Rl7Pct; resets_at = $Rl7ResetsAt }
    }
    if ($rateLimits.Count -gt 0) { $payload.rate_limits = $rateLimits }
    return $payload
}

function Invoke-Statusline {
    param(
        [Parameter(Mandatory)] [hashtable]$Payload,
        [long]$NowEpoch = 0
    )
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $psArgs = @('-NoProfile', '-File', $script:StatuslinePath)
    if ($NowEpoch -gt 0) {
        $psArgs += '-NowEpoch'
        $psArgs += $NowEpoch.ToString()
    }
    # Pipe JSON to the child's stdin via the call operator.
    $output = $json | & powershell @psArgs 2>&1
    return ($output | Out-String)
}

function Strip-Ansi {
    param([string]$Text)
    # Win PS 5.1 doesn't support the `e escape; build the pattern with [char]0x1B.
    $esc = [char]0x1B
    return ($Text -replace ("$esc" + '\[[0-9;]*m'), '')
}

function Get-Line {
    param([string]$Output, [int]$Index)
    $lines = $Output -split "`r?`n"
    return $lines[$Index]
}
