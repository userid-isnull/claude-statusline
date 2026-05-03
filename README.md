# claude-statusline

Custom two-line status display for Claude Code. PowerShell variant
for Windows (`statusline.ps1`); bash variant for Linux / macOS
(`statusline.sh`).

```
 ▓░░░ 27% (54K) / 200K | 5h ▓░░░ 18% 14:30 | 7d ▓▓▓░░░░ 41%/51% Wed (4d)
 my-project  main [+!] | a1b2c3d4
```

> The PowerShell variant has been redesigned per the layout above. The bash
> variant still renders the older layout (10-segment context bar, 4-segment
> 7d bar, ↑/↓ tokens, no pace meter); it will be ported in a separate
> `feat/fss-wsl/...` branch.

## What it shows

**Line 1 (PowerShell variant)**

- **Context bar (4 segments)** — filled-count and color encode the **token count in the current session** as danger-zone bands, not percentage tenths:
  - `< 100K` → 1 segment, default color
  - `100K–200K` → 2 segments, yellow
  - `200K–350K` → 3 segments, red
  - `≥ 350K` → 4 segments, vivid magenta
- **Used percentage and token count**, e.g. `27% (54K)`, followed by the context window size.
- **5-hour rate-limit bar** (4 segments) with percent and reset time.
- **7-day rate-limit bar (7 segments)** with `<actual>%/<pace>%`. *Pace* is where you'd be in the 168-hour window if usage were perfectly uniform — derived from how much time has elapsed since the last reset. When actual is below pace, the segments between the actual-filled run and the pace position are shaded **green** to show the buffer you have in hand.
- **Reset slot** — day-of-week (`Wed`) when ≥ 24 h to reset, or reset time (`19:10`) when < 24 h.
- **Countdown** — parenthesized: `(4d)` when ≥ 24 h remain (whole days), `(3h)` when < 24 h (whole hours).

**Line 2** — Git repo name, branch (or worktree name), status icons (`+` staged, `!` modified, `?` untracked), working directory (if different from project root), and session ID. When connected via SSH, shows a color-coded `user@host` prefix using your Starship palette.

## Tests (PowerShell variant)

Pester 5+ test suite under `tests/`:

```powershell
powershell -NoProfile -File tests\run.ps1
```

Tests use a `-NowEpoch` script parameter on `statusline.ps1` so pace and
countdown calculations are deterministic. Production renders use the system
clock; the parameter is for test injection only.

## Requirements

**Windows**: PowerShell 5.1+. **Linux / macOS**: bash + `jq`.
Both: Claude Code with `statusLine` support; a
[Nerd Font](https://www.nerdfonts.com/) for the branch glyph
(optional but recommended); [Starship](https://starship.rs/) with a
palette for SSH host coloring (optional).

## Install

### Windows (quick)

```powershell
git clone https://github.com/userid-isnull/claude-statusline
cd claude-statusline
powershell -NoProfile -File install.ps1
```

The installer copies `statusline.ps1` to `~/.claude/` and adds the
statusLine config to `~/.claude/settings.local.json`.

### Linux / macOS (quick)

```bash
git clone https://github.com/userid-isnull/claude-statusline
cd claude-statusline
bash install.sh
```

The installer copies `statusline.sh` to `~/.claude/`, sets
`statusLine` in `~/.claude/settings.local.json`, and adds the
matching `permissions.allow` entry. Idempotent — safe to re-run.

### Side-effect: rate-limit JSON dump

`statusline.sh` (Linux / macOS only) tees the JSON payload it
receives from Claude Code to `/tmp/statusline-${session_id}.json`
and `/tmp/statusline-latest.json` before rendering. This is the
only practical way to read the live `rate_limits.*` values
out-of-band — Claude Code only exposes them to the statusline
command, not to hooks, stream-json, or `/status` in `-p` mode. The
dump files are tiny (~1 KB), gitignored by your shell's `/tmp`, and
overwritten on every render.

### Manual

1. Copy the appropriate script to `~/.claude/`:
   - Windows: `statusline.ps1`
   - Linux / macOS: `statusline.sh` (must be executable)

2. Add to `~/.claude/settings.local.json`:

   Windows:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/YOURNAME/.claude/statusline.ps1",
       "padding": 1
     }
   }
   ```

   Linux / macOS:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 1
     }
   }
   ```

3. Add the corresponding `Bash(~/.claude/statusline.{sh|ps1})`
   entry to `permissions.allow` in `~/.claude/settings.json` or
   `settings.local.json` so Claude Code can run the script without
   prompting.

4. Restart Claude Code.

## Troubleshooting

If the statusline doesn't appear and there are no errors in the session:

### 1. Verify settings.local.json was written correctly

Open `~/.claude/settings.local.json` and confirm the `statusLine` block is present and valid JSON. A common issue is the installer merging into an existing file incorrectly. It should contain:

```json
"statusLine": {
  "type": "command",
  "command": "powershell -NoProfile -File C:/Users/YOURNAME/.claude/statusline.ps1",
  "padding": 1
}
```

Make sure the path in `command` matches the actual location of the script and uses forward slashes.

### 2. Check that the script file exists

From a PowerShell prompt:

```powershell
Test-Path "$env:USERPROFILE\.claude\statusline.ps1"
```

### 3. Test the script manually

Claude Code pipes JSON to the script on stdin. Simulate this from PowerShell:

```powershell
'{"context_window":{"used_percentage":42,"context_window_size":200000,"total_input_tokens":50000,"total_output_tokens":12000},"session_id":"test123"}' | powershell -NoProfile -File "$env:USERPROFILE\.claude\statusline.ps1"
```

You should see two lines of output. If you get errors, they'll appear here.

### 4. Verify PowerShell is accessible from bash

Claude Code runs the statusline command through its bash shell. Confirm `powershell` is on the PATH from bash (not just from PowerShell/cmd):

Open a Git Bash or WSL terminal and run:

```bash
which powershell
powershell -NoProfile -Command "Write-Host ok"
```

If `powershell` isn't found, try using the full path in the statusLine command. Edit `~/.claude/settings.local.json` and change the command to:

```json
"command": "powershell.exe -NoProfile -File C:/Users/YOURNAME/.claude/statusline.ps1"
```

Or use the full path to PowerShell:

```json
"command": "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -File C:/Users/YOURNAME/.claude/statusline.ps1"
```

### 5. Check for conflicting statusLine config

The `statusLine` key can appear in multiple settings files. Claude Code merges them with this precedence (highest first):

1. Project-level: `.claude/settings.local.json` (in the project directory)
2. User-level: `~/.claude/settings.local.json`
3. User-level: `~/.claude/settings.json`

If a project-level config exists with its own `statusLine` (or without one), it may override yours. Check for `.claude/settings.local.json` in the project directory you're working in.

### 6. Restart Claude Code

The statusline config is read at startup. If you changed settings after launching, exit and relaunch Claude Code.

## Notes

- Git status is cached for 5 seconds in `%TEMP%\claude-sl-git.txt` to keep the statusline snappy.
- SSH host color is pulled from your `starship.toml` palette (`color1` key).
- Line 2 wraps the session ID to a third line if the total exceeds 90 characters.
