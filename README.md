# claude-status-line

A custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows session metrics and workspace info, replicating the shell prompt that Claude Code hides during a session.

## Layout

The status line renders exactly two lines.

**Line 1 — Model, context window, and rate limits:**

```
Opus:high ▓▓░░ 13% (135K) / 1.0M | 5h ░░░░ 4% 02:50 | 7d ▓▓▓▓▓░░ 72%/83% Wed (1d3h) | s7d ▓▓░░░░░ 33%/83%
```

**Line 2 — Workspace (starship-style) and session ID:**

```
my-project  main [+!?] | 776fca86-0d70-46cf-a18a-182e73101fc6
```

## Line 1 breakdown

| Segment | Example | Source field | Formula / logic |
|---------|---------|-------------|-----------------|
| Model + effort prefix | `Opus:high` | `model.display_name`, `effort.level` | First word of `display_name` (so `Opus 4.7 (1M context)` → `Opus`). When `effort.level` is present, append `:<level>` (`low`/`medium`/`high`/`xhigh`/`max`). Effort is absent for models that don't support it (Haiku) — then just the bare name. The full version + context size are inferred from the `/ 1.0M` size segment instead of the model label, keeping line 1 tight. |
| Context bar | `▓▓░░` | `context_window.current_usage.*` | 4 segments, danger bands by **exact token count**: 1 seg <100K (default), 2 yellow ≥100K, 3 red ≥200K, 4 magenta ≥350K. Color applied only to filled run. |
| Context percentage | `13%` | `context_window.used_percentage` | `floor()` of the raw value. |
| Current tokens | `(135K)` | `current_usage.input + output + cache_creation + cache_read` | Falls back to `floor(used_pct * ctx_size / 100)` when `current_usage` is null (early in session). |
| Context window size | `/ 1.0M` | `context_window.context_window_size` | Formatted: <1K raw, 1K-999K as `NK`, ≥1M as `N.NM`. |
| 5-hour rate limit bar | `░░░░` | `rate_limits.five_hour.used_percentage` | 4 segments, each = 25%. Filled = `(pct + 12) / 25`. |
| 5-hour percentage | `4%` | same | `floor()` of the raw value. |
| 5-hour reset time | `02:50` | `rate_limits.five_hour.resets_at` | Unix epoch → local time-of-day (`HH:MM`). |
| 7-day rate limit bar | `▓▓▓▓▓░░` | `rate_limits.seven_day.used_percentage` | 7 segments. Fill count = `floor((14·pct + 100) / 200)`, capped at 7 — fills when pct crosses each segment's halfway mark (1/14, 3/14, …, 13/14). |
| 7-day pace overlay | `▓▓▓▓▓`<span style="color:green">`░`</span>`░` | derived from `rate_limits.seven_day.resets_at` | Pace = `floor(100·(168 − hours_to_reset)/168)`. The (pace_filled − actual_filled) segments immediately after the actual run are tinted green to show how far through the 168h window you should be. |
| 7-day actual / pace | `72%/83%` | computed | Percentage actually used / percentage expected by now. |
| 7-day reset | `Wed` or `02:50` | `rate_limits.seven_day.resets_at` | If reset is **<24h away**: time-of-day (`HH:MM`). Otherwise: abbreviated day name (`ddd`). |
| 7-day countdown | `(1d3h)` | derived | `(NdMh)` ≥24h, `(Nh)` <24h, `(0h)` if past. |
| Sonnet 7d bar + actual/pace | `s7d ▓▓░░░░░ 33%/83%` | `rate_limits.seven_day_sonnet.*` *or* `rate_limits.seven_day.sonnet.*` (probed defensively) | Same 7-segment + pace render as `7d`, but **without** the day-of-week or countdown (those duplicate the all-models segment). Suppressed entirely when no Sonnet field is present. |

The rate limit sections (`5h …`, `7d …`, `s7d …`) only appear when the corresponding JSON fields are populated. Each section is separated by ` | `.

> **Sonnet field availability:** As of Claude Code 2.1.128 there is no documented Sonnet-only 7d field in the statusline JSON — only `rate_limits.five_hour` and `rate_limits.seven_day`. The `s7d` segment is wired up to two probable paths (`rate_limits.seven_day_sonnet` and `rate_limits.seven_day.sonnet`) so it lights up automatically the moment Anthropic exposes one. Until then it stays silent.

## Line 2 breakdown

Line 2 mimics a [Starship](https://starship.rs/) prompt. The format varies by scenario:

| Scenario | Example |
|----------|---------|
| Local, no git | `~/tinkery/my-project \| 776fca86-...` |
| Local, git | `my-project  main [!?] \| 776fca86-...` |
| Local, git + different cwd | `my-project  main [!?] > ./subdir \| 776fca86-...` |
| Local, no git + different cwd | `my-project > ./subdir \| 776fca86-...` |
| SSH, git | `id@oam my-project  main [!?] \| 776fca86-...` |
| Worktree | `my-project  wt-name [!?] \| 776fca86-...` |

| Segment | Source field | Logic |
|---------|-------------|-------|
| SSH host prefix | `$SSH_CONNECTION` env var | Only shown in SSH sessions. Styled with bold + inverted + true color from the active Starship palette's `color1`. |
| Project path | `workspace.project_dir` | Git repos: basename only. Non-git: full path with `~` home abbreviation. |
| Branch / worktree | `git branch --show-current` / `worktree.name` | `` (U+E0A0 Powerline icon) + name. Worktree name replaces branch when present. |
| Git status | `git diff`, `git ls-files` | Presence-only icons in brackets: `+` staged, `!` modified, `?` untracked. No counts. |
| Working directory | `workspace.current_dir` | Shown as `> ./relative` only when different from project dir. |
| Session ID | `session_id` | UUID at end, separated by ` \| `. |

**Width limit:** 90 characters. If line 2 exceeds this, the session ID wraps to a new line.

## Out-of-band JSON capture

Claude Code only exposes `rate_limits.*` to the statusline command — not to hooks or stream-json. The bash script tees its stdin payload to two files on every render:

- `/tmp/statusline-${session_id}.json` — per-session capture, races-free across concurrent sessions
- `/tmp/statusline-latest.json` — always the most recent payload from any session

This lets other tools on the machine (cron jobs, dashboards, debugging scripts) read live rate-limit data without subscribing to Claude Code internals.

## Deterministic test clock

The script honors `STATUSLINE_NOW_EPOCH` (env var) — when set to a Unix timestamp, all "now"-relative computations (pace, countdown, "is reset today?") use that value instead of the system clock.

```sh
# Pin the clock for repeatable rendering
STATUSLINE_NOW_EPOCH=1715000000 ./statusline.sh < captured.json
```

This is purely for tests/demos; production runs always use the live clock.

## Requirements

- bash 4.4+ (Linux, macOS, WSL, or Git Bash on Windows — Claude Code on Windows already routes statusLine commands through Git Bash)
- [jq](https://jqlang.github.io/jq/)
- `awk` (for float division in `get_pace`)
- GNU or BSD `date` (both supported via the `epoch_fmt` helper)
- A [Nerd Font](https://www.nerdfonts.com/) (for the `` branch icon)

Installing jq:
- **Debian/Ubuntu:** `sudo apt install jq`
- **macOS (Homebrew):** `brew install jq`
- **Windows (scoop):** `scoop install jq`
- **Windows (winget):** `winget install jqlang.jq`

## Installation

Clone into `~/repos/` (the conventional home for upstream clones — keeps your dev checkout decoupled from the deployed copy that Claude Code actually reads), then run the installer:

```sh
git clone https://github.com/userid-isnull/claude-statusline.git ~/repos/claude-statusline
bash ~/repos/claude-statusline/install.sh
```

`install.sh` copies `statusline.sh` into `~/.claude/`, adds the `statusLine` block to `~/.claude/settings.local.json`, and registers the matching `permissions.allow` entry — all idempotent, safe to re-run after `git pull`. After install, the only path that runs at session-start is `~/.claude/statusline.sh`; your clone in `~/repos/` is just for development.

If you'd rather wire it up by hand:

```sh
cp ~/repos/claude-statusline/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 1
  }
}
```

The `bash` prefix makes the command portable across Linux, macOS, WSL, and Windows-via-Git-Bash without depending on shebang/exec-bit handling. On Windows, Claude Code locates Git Bash automatically.

### Updating

```sh
git -C ~/repos/claude-statusline pull && bash ~/repos/claude-statusline/install.sh
```

`install.sh` is idempotent, so the second run just refreshes `~/.claude/statusline.sh` from the new upstream and leaves the settings entries untouched.

### Verify

Start a new Claude Code session. The status line appears after the first assistant message.

Test the bash script directly:

```sh
echo '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42,"context_window_size":200000,"current_usage":{"input_tokens":50000,"output_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"workspace":{"project_dir":"'$HOME'/test","current_dir":"'$HOME'/test"},"session_id":"test-1234"}' | ~/.claude/statusline.sh
```

## Deploying to other machines

The same script runs on every host. The cleanest pattern is to clone+install on each:

```sh
ssh user@host '
  git clone https://github.com/userid-isnull/claude-statusline.git ~/repos/claude-statusline
  bash ~/repos/claude-statusline/install.sh
'
```

Or, if you just want to push the deployed script directly without cloning:

```sh
scp statusline.sh user@host:~/.claude/statusline.sh
ssh user@host chmod +x ~/.claude/statusline.sh
```

Each host reads its own `~/.config/starship.toml` at runtime for SSH colors, so no per-host customization is needed.

**Current deployments:**

| Host | OS | Notes |
|------|----|-------|
| fss-wsl | WSL2 Ubuntu (local) | |
| fss | Windows 11 (local) | runs through Git Bash |
| oam | macOS | |
| xhp | Debian 13 | jq installed via `sudo apt install jq` |

All hosts use `~/.claude/statusline.sh` with `~/.claude/settings.json` pointing at `bash ~/.claude/statusline.sh`.

## SSH host colors

When connected via SSH (detected via `$SSH_CONNECTION`), the status line prepends `user@host` styled with your Starship palette. The script:

1. Reads `~/.config/starship.toml` (or `$STARSHIP_CONFIG`)
2. Finds the active `palette = "name"` line
3. Looks up `color1` in the matching `[palettes.name]` section
4. Converts the hex color to ANSI true color: `ESC[1;7;38;2;R;G;Bm` (bold + inverted + 24-bit foreground)

This matches Starship's `style_user = "color1 bold inverted"`. Each machine has its own palette in its own `starship.toml`, so colors automatically differ per host.

## How it works

Claude Code's [status line feature](https://docs.anthropic.com/en/docs/claude-code/statusline) runs a configured command after each assistant message (debounced at 300ms). The command receives a JSON payload on stdin and prints two lines to stdout.

The `statusLine` property in `~/.claude/settings.json` configures this:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

### JSON fields used

| Field | Type | Used for |
|-------|------|----------|
| `model.display_name` | string | Short model prefix on line 1 (first word only) |
| `effort.level` | string (absent for non-reasoning models) | Appended to model prefix as `:<level>` |
| `context_window.used_percentage` | number (nullable) | Context percentage |
| `context_window.context_window_size` | number | Context window total (200K, 1M, etc.) |
| `context_window.current_usage.input_tokens` | number (nullable) | Sums into exact current token count |
| `context_window.current_usage.output_tokens` | number (nullable) | ″ |
| `context_window.current_usage.cache_creation_input_tokens` | number (nullable) | ″ |
| `context_window.current_usage.cache_read_input_tokens` | number (nullable) | ″ |
| `workspace.project_dir` | string | Project path display |
| `workspace.current_dir` | string | Working directory (if different) |
| `session_id` | string | Session UUID + per-session JSON tee filename |
| `worktree.name` | string (absent if not worktree) | Replaces branch name |
| `rate_limits.five_hour.used_percentage` | number (absent if not Max) | 5h bar + percentage |
| `rate_limits.five_hour.resets_at` | number (absent if not Max) | 5h reset time |
| `rate_limits.seven_day.used_percentage` | number (absent if not Max) | 7d bar + percentage |
| `rate_limits.seven_day.resets_at` | number (absent if not Max) | 7d reset time/day + countdown + pace |
| `rate_limits.seven_day_sonnet.used_percentage` | number (undocumented; absent today) | s7d bar + percentage, when present |
| `rate_limits.seven_day_sonnet.resets_at` | number (undocumented; absent today) | s7d pace, when present |

### Performance

- **Single jq invocation:** all 18 fields extracted in one call, parsed with `IFS=$'\x1f' read`. Avoids forking `jq` per-field.
- **Git caching:** git status is cached in a temp file with a 5-second TTL. On cache hit, zero git commands run.
- **Early-exit git checks:** `head -1` on git output avoids reading full diffs just to check if changes exist.
- **Buffered output:** one final `printf` call emits both lines, avoiding pty-flush splits that would otherwise render line 1 alone for a frame.

## Tests

```sh
bash tests/run.sh
```

Runs a 51-case bash assertion suite covering every line-1 feature (context bands, current_usage preference, 7-segment 7d bar, pace meter, green pace-buffer overlay, countdown formatting, sonnet `s7d`, model:effort prefix, graceful handling when `rate_limits` is absent). Tests pin the clock via `STATUSLINE_NOW_EPOCH=1747000000` so pace and countdown are deterministic across hosts.
