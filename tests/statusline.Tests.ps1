# Pester 5+ test suite for statusline.ps1.
# Run via: powershell -NoProfile -File tests\run.ps1

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    # Fixed reference epoch so pace/countdown calculations are deterministic.
    # 1747000000 = 2025-05-12 04:46:40 UTC.
    $script:NOW = [long]1747000000
    # Win PS 5.1 doesn't support `e in double-quoted strings (added in PS 6).
    # Use this constant in regexes to inject the literal ESC byte.
    $script:ESC = [char]0x1B
}

Describe 'context window bands' {

    It 'default (no color), 1 segment, when current_tokens < 100K' {
        $payload = New-StatuslinePayload -UsedPct 5 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓░░░ 5% \(50K\) / 1\.0M'
        $line1    | Should -Not -Match ("$script:ESC" + '\[33m')
        $line1    | Should -Not -Match ("$script:ESC" + '\[31m')
        $line1    | Should -Not -Match ("$script:ESC" + '\[95m')
    }

    It 'yellow + 2 segments at exactly 100K tokens' {
        $payload = New-StatuslinePayload -UsedPct 10 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓▓░░ 10% \(100K\) / 1\.0M'
        $line1    | Should -Match ("$script:ESC" + '\[33m')
    }

    It 'red + 3 segments at exactly 200K tokens' {
        $payload = New-StatuslinePayload -UsedPct 20 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓▓▓░ 20% \(200K\) / 1\.0M'
        $line1    | Should -Match ("$script:ESC" + '\[31m')
        $line1    | Should -Not -Match ("$script:ESC" + '\[33m')
    }

    It 'vivid magenta + 4 segments at exactly 350K tokens' {
        $payload = New-StatuslinePayload -UsedPct 35 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓▓▓▓ 35% \(350K\) / 1\.0M'
        $line1    | Should -Match ("$script:ESC" + '\[95m')
    }

    It 'still magenta + 4 segments at 900K tokens' {
        $payload = New-StatuslinePayload -UsedPct 90 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓▓▓▓ 90% \(900K\) / 1\.0M'
        $line1    | Should -Match ("$script:ESC" + '\[95m')
    }

    It 'uses exact current_usage sum when present (not the percentage estimate)' {
        # used_pct=5 and ctx_size=1M would estimate 50K, but current_usage
        # sums to 46,727 -> displays as (46K) and stays in the default band.
        $cu = @{
            input_tokens                 = 6
            output_tokens                = 160
            cache_creation_input_tokens  = 1232
            cache_read_input_tokens      = 45329
        }
        $payload = New-StatuslinePayload -UsedPct 5 -CtxSize 1000000 -CurrentUsage $cu
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match '^▓░░░ 5% \(46K\) / 1\.0M'
    }

    It 'pushes to yellow band when current_usage crosses 100K even if used_percentage is small' {
        # used_pct=10 estimates 100K too, but here we make it explicit at 120K.
        $cu = @{ input_tokens = 120000 }
        $payload = New-StatuslinePayload -UsedPct 10 -CtxSize 1000000 -CurrentUsage $cu
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓▓░░ 10% \(120K\) / 1\.0M'
        $line1    | Should -Match ("$script:ESC" + '\[33m')
    }
}

Describe 'up/down tokens removed' {

    It 'never emits arrow glyphs on Line 1' {
        $payload = New-StatuslinePayload -UsedPct 5 -CtxSize 1000000 -InTokens 23000 -OutTokens 2000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $line1 | Should -Not -Match '↑'
        $line1 | Should -Not -Match '↓'
    }
}

Describe '7-segment 7d bar with halfway-cross thresholds' {

    BeforeAll {
        function Assert-7dBarFilled {
            param([int]$Pct, [int]$Expected, [long]$Now)
            $payload = New-StatuslinePayload -UsedPct 5 -CtxSize 1000000 `
                -Rl7Pct $Pct -Rl7ResetsAt ($Now + 168 * 3600)
            $out = Invoke-Statusline -Payload $payload -NowEpoch $Now
            $line1 = ($out -split "`r?`n")[0]
            $stripped = Strip-Ansi $line1
            if ($stripped -match '7d (\S{7}) ') {
                $bar = $Matches[1]
            } else {
                throw "Could not extract 7d bar from: $stripped"
            }
            $filled = ($bar.ToCharArray() | Where-Object { $_ -eq [char]0x2593 } | Measure-Object).Count
            $filled | Should -Be $Expected
        }
    }

    It 'pct 0 fills 0 segments'   { Assert-7dBarFilled -Pct 0   -Expected 0 -Now $script:NOW }
    It 'pct 7 fills 0 segments'   { Assert-7dBarFilled -Pct 7   -Expected 0 -Now $script:NOW }
    It 'pct 8 fills 1 segment'    { Assert-7dBarFilled -Pct 8   -Expected 1 -Now $script:NOW }
    It 'pct 21 fills 1 segment'   { Assert-7dBarFilled -Pct 21  -Expected 1 -Now $script:NOW }
    It 'pct 22 fills 2 segments'  { Assert-7dBarFilled -Pct 22  -Expected 2 -Now $script:NOW }
    It 'pct 41 fills 3 segments'  { Assert-7dBarFilled -Pct 41  -Expected 3 -Now $script:NOW }
    It 'pct 50 fills 4 segments'  { Assert-7dBarFilled -Pct 50  -Expected 4 -Now $script:NOW }
    It 'pct 92 fills 6 segments'  { Assert-7dBarFilled -Pct 92  -Expected 6 -Now $script:NOW }
    It 'pct 93 fills 7 segments'  { Assert-7dBarFilled -Pct 93  -Expected 7 -Now $script:NOW }
    It 'pct 100 fills 7 segments' { Assert-7dBarFilled -Pct 100 -Expected 7 -Now $script:NOW }
}

Describe 'pace meter (numeric)' {

    It 'pace ~25% when 126h remain' {
        $payload = New-StatuslinePayload -Rl7Pct 0 -Rl7ResetsAt ($script:NOW + 126 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match ' 0%/25% '
    }

    It 'pace = 0% just after a reset (168h remain)' {
        $payload = New-StatuslinePayload -Rl7Pct 0 -Rl7ResetsAt ($script:NOW + 168 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match ' 0%/0% '
    }

    It 'pace = 99% when 1h remains' {
        $payload = New-StatuslinePayload -Rl7Pct 0 -Rl7ResetsAt ($script:NOW + 1 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match ' 0%/99% '
    }

    It 'renders actual/pace numeric pair when both are nonzero' {
        # pace 51% requires hoursToReset in (80.64, 82.32]; pick 82h.
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 82 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match ' 41%/51% '
    }
}

Describe 'green buffer shading on 7d bar' {

    It 'inserts green segments between actual-filled and tail when actual is below pace' {
        # actual=41 -> aFilled=3; pace=51 -> pFilled=4; bufN=1 green.
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 82 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        # The 7d bar with green should look like: ▓▓▓<ESC>[32m░<ESC>[0m░░░
        $line1 | Should -Match ('▓▓▓' + "$script:ESC" + '\[32m░+' + "$script:ESC" + '\[0m')
    }

    It 'no green when actual >= pace' {
        # actual=60 -> aFilled=4; pace=51 -> pFilled=4; bufN=0.
        $payload = New-StatuslinePayload -Rl7Pct 60 -Rl7ResetsAt ($script:NOW + 82 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        # Ensure no green ESC[32m anywhere on line 1.
        $line1 | Should -Not -Match ("$script:ESC" + '\[32m')
    }
}

Describe 'reset countdown' {

    It 'shows (4d2h) when 98h remain (NdMh format above 24h)' {
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 98 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match '\(4d2h\)\s*$'
    }

    It 'shows day-of-week (not HH:mm) in the slot when at least 24h remain' {
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 98 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        # Pattern: ACTUAL%/PACE% DOW (NdMh) -- e.g. "41%/41% Wed (4d2h)"
        $stripped | Should -Match ' \d{1,3}%/\d{1,3}% (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \(\d+d\d+h\)\s*$'
    }

    It 'shows (1d0h) at exactly 24h' {
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 24 * 3600)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match '\(1d0h\)\s*$'
    }

    It 'shows (3d4h) when 76h22m remain (matches the Sat-to-Wed-02:00 case)' {
        # 76h22m = 274920 seconds. Days=3, rem=4. Sanity check from live data.
        $payload = New-StatuslinePayload -Rl7Pct 49 -Rl7ResetsAt ($script:NOW + 274920)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match '\(3d4h\)\s*$'
    }

    It 'shows (3h) and HH:mm slot when 3h15m remain (under 24h)' {
        $payload = New-StatuslinePayload -Rl7Pct 41 -Rl7ResetsAt ($script:NOW + 3 * 3600 + 15 * 60)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match ' \d{1,3}%/\d{1,3}% \d{1,2}:\d{2} \(3h\)\s*$'
    }

    It 'shows (0h) when only 30 minutes remain (acceptable lower bound)' {
        $payload = New-StatuslinePayload -Rl7Pct 95 -Rl7ResetsAt ($script:NOW + 30 * 60)
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi (($out -split "`r?`n")[0])
        $stripped | Should -Match '\(0h\)\s*$'
    }
}

Describe 'graceful handling' {

    It 'omits 5h and 7d sections when rate_limits is absent' {
        $payload = New-StatuslinePayload -UsedPct 5 -CtxSize 1000000
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $line1 = ($out -split "`r?`n")[0]
        $stripped = Strip-Ansi $line1
        $stripped | Should -Match '^▓░░░ 5% \(50K\) / 1\.0M\s*$'
        $stripped | Should -Not -Match ' 5h '
        $stripped | Should -Not -Match ' 7d '
    }
}

Describe 'Line 2 (workspace + session id)' {

    It 'still emits the session id on Line 2' {
        $payload = New-StatuslinePayload -SessionId 'abc-123-test' -ProjectDir 'C:/tmp/proj'
        $out = Invoke-Statusline -Payload $payload -NowEpoch $script:NOW
        $stripped = Strip-Ansi $out
        $stripped | Should -Match 'abc-123-test'
    }
}
