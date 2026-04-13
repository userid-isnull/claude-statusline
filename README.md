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

## Notes

- Git status is cached for 5 seconds in `%TEMP%\claude-sl-git.txt` to keep the statusline snappy.
- SSH host color is pulled from your `starship.toml` palette (`color1` key).
- Line 2 wraps the session ID to a third line if the total exceeds 90 characters.
