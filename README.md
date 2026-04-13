# claude-statusline

Custom two-line status display for Claude Code on Windows.

```
 ▓▓▓░░░░░░░ 27% / 200K | ↑54K ↓12K | 5h ▓░░░ 18% 14:30 | 7d ░░░░ 3% Thu
 my-project  main [+!] | a1b2c3d4
```

## What it shows

**Line 1** — Context window usage bar and percentage, context size, input/output token counts, 5-hour and 7-day rate limit bars with reset times.

**Line 2** — Git repo name, branch (or worktree name), status icons (`+` staged, `!` modified, `?` untracked), working directory (if different from project root), and session ID. When connected via SSH, shows a color-coded `user@host` prefix using your Starship palette.

## Requirements

- Windows with PowerShell 5.1+
- Claude Code with statusLine support
- A [Nerd Font](https://www.nerdfonts.com/) for the branch glyph (optional but recommended)
- [Starship](https://starship.rs/) with a palette for SSH host coloring (optional)

## Install

### Quick

```powershell
git clone https://github.com/userid-isnull/claude-statusline
cd claude-statusline
powershell -NoProfile -File install.ps1
```

The installer copies `statusline.ps1` to `~/.claude/` and adds the statusLine config to `~/.claude/settings.local.json`.

### Manual

1. Copy `statusline.ps1` to `~/.claude/statusline.ps1`

2. Add to `~/.claude/settings.local.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/YOURNAME/.claude/statusline.ps1",
       "padding": 1
     }
   }
   ```

3. Add `"Bash(~/.claude/statusline.ps1)"` to `permissions.allow` in `~/.claude/settings.json` or `settings.local.json` so Claude Code can run the script without prompting.

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
