# claude-status-line

A custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows session metrics and workspace info, replicating the shell prompt that Claude Code hides during a session. Claude Code and the omp footer extension are both consumers of this renderer.

## Layout

The renderer always emits a payload row and a workspace row. Between them it inserts a cache row whenever the `omp usage --json` cache contributed a window that Claude Code's own payload cannot carry, and it appends the active worktree row last when the session is inside a linked worktree. The split is by provenance, not by width: the payload has no terminal-width field, so a fixed rule is the only one that cannot mis-wrap. It also keeps the first row inside about 85 columns.

**Payload row (first) — everything Claude Code itself supplies:**

```
Opus:high ▓▓░░ 13% (135K)/1.0M | 5h 4% 02:50 | 7d 72%/83% Wed (1d3h) | s7d 33%/83%
```

**Cache row (only when the usage cache adds a window):**

```
f7d 58%/75% | c5h 10%/60% | c7d 20%/87% | cs5h 30%/40% | cs7d 40%/75%
```

**Workspace row:**

```
my-project  main [+!?] | 776fca86-0d70-46cf-a18a-182e73101fc6
```

**Active git worktree row (only inside a linked worktree):**

```
 ../.worktrees/my-project/my-branch
```

## Payload and cache row breakdown

| Segment | Example | Source field | Formula / logic |
|---------|---------|-------------|-----------------|
| Model + effort prefix | `Opus:high` | `model.display_name`, `effort.level` | First word of `display_name` (so `Opus 4.7 (1M context)` → `Opus`). When `effort.level` is present, append `:<level>` (`low`/`medium`/`high`/`xhigh`/`max`). Effort is absent for models that do not support it (Haiku) — then just the bare name. |
| Context bar | `▓▓░░` | `context_window.current_usage.*` | The only bar in the renderer: 4 segments, danger bands by **exact token count**. One default segment <100K, two yellow ≥100K, three red ≥200K, four magenta ≥350K. Color applies only to the filled run. |
| Context percentage | `13%` | `context_window.used_percentage` | `floor()` of the raw value. |
| Current tokens | `(135K)` | `current_usage.input + output + cache_creation + cache_read` | Falls back to `floor(used_pct * ctx_size / 100)` when `current_usage` is null (early in session). It joins the window size without a surrounding slash space: `(135K)/1.0M`. |
| Context window size | `/1.0M` | `context_window.context_window_size` | Formatted: <1K raw, 1K-999K as `NK`, ≥1M as `N.NM`. |
| 5-hour usage | `5h 4%` | `rate_limits.five_hour.used_percentage` | Uncolored percentage with no bar. |
| 5-hour reset time | `02:50` | `rate_limits.five_hour.resets_at` | Optional Unix epoch → local time-of-day (`HH:MM`). |
| 7-day actual / pace | `7d 72%/83%` | `rate_limits.seven_day.*` | No bar. The actual `72%` token is green when actual ≤ pace and red when actual > pace. The `/83%` pace half stays default-colored. |
| 7-day reset | `Wed` or `02:50` | `rate_limits.seven_day.resets_at` | If reset is **<24h away**: time-of-day (`HH:MM`). Otherwise: abbreviated day name (`ddd`). |
| 7-day countdown | `(1d3h)` | derived | `(NdMh)` ≥24h, `(Nh)` <24h, `(0h)` if past. |
| Sonnet 7d actual / pace | `s7d 33%/83%` | `rate_limits.seven_day_sonnet.*` *or* `rate_limits.seven_day.sonnet.*` (probed defensively) | Same colored actual / uncolored pace rule as `7d`, without a day or countdown. Suppressed entirely when no Sonnet field is present. |
| Fable 7d actual / pace | `f7d 58%/75%` | `omp usage --json`: `anthropic:7d:fable` | Same colored actual / uncolored pace rule as `s7d`. Cache row. |
| Codex 5h actual / pace | `c5h 10%/60%` | `omp usage --json`: non-Spark `openai-codex` limit for `5h` | Same colored actual / uncolored pace rule, paced from that limit's own window duration. Cache row. |
| Codex 7d actual / pace | `c7d 20%/87%` | `omp usage --json`: non-Spark `openai-codex` limit for `7d` | Same colored actual / uncolored pace rule, paced from that limit's own window duration. Cache row. |
| Spark Codex 5h actual / pace | `cs5h 30%/40%` | `omp usage --json`: Spark `openai-codex` limit for `5h` | `cs` keeps Spark visibly separate from ordinary Codex; same color rule. Cache row. |
| Spark Codex 7d actual / pace | `cs7d 40%/75%` | `omp usage --json`: Spark `openai-codex` limit for `7d` | `cs` keeps Spark visibly separate from ordinary Codex; same color rule. Cache row. |

The payload sections (`5h …`, `7d …`, `s7d …`) only appear when populated and are separated by ` | `. The cache row holds `f7d`, `c5h`, `c7d`, `cs5h`, and `cs7d`, in that fixed order with no leading separator, and exists only when at least one of them has data.

A window that reports a percentage but no reset time has no knowable pace — `omp usage --json` omits `window.resetsAt` on a window nothing has spent yet — so that segment degrades to a bare uncolored percentage (`f7d 0%`) and keeps its place. It is never dropped, and it never claims a pace of zero. The same rule applies to `7d`, which then also loses its reset and countdown.

### omp-backed limits

When enabled, the renderer reads the verbatim `omp usage --json` cache at `${STATUSLINE_OMP_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/omp-usage.json}`. It can consume that cache without an `omp` binary; when the cache is at least `STATUSLINE_OMP_TTL` seconds old and `omp` is available, it refreshes it with `omp usage --json`. The default TTL is 60 seconds, and a failed refresh keeps the previous cache. The omp footer extension sets a 300-second TTL after it writes the cache so this renderer trusts that fresh snapshot rather than spawning `omp`.

Only limits whose `amount.unit` is `percent` render. Cache data gap-fills individual missing `5h`, `7d`, and `s7d` payload fields; a value present in the Claude Code payload always wins. Codex labels use `scope.windowId`, then `window.id`, then a `durationMs` fallback (`18000000` → `5h`, `604800000` → `7d`). A Spark tier (`scope.tier == "spark"` or an id containing `:spark:`) gets the `cs` prefix. Unknown window kinds are omitted.

> **Sonnet field availability:** As of Claude Code 2.1.128 there is no documented Sonnet-only 7d field in the statusline JSON — only `rate_limits.five_hour` and `rate_limits.seven_day`. The `s7d` segment is wired up to two probable paths (`rate_limits.seven_day_sonnet` and `rate_limits.seven_day.sonnet`) so it lights up automatically the moment Anthropic exposes one. Until then it stays silent.

## Workspace row breakdown

The workspace row mimics a [Starship](https://starship.rs/) prompt. The format varies by scenario:

| Scenario | Example |
|----------|---------|
| Local, no git | `~/tinkery/my-project \| 776fca86-...` |
| Local, git | `my-project  main [!?] \| 776fca86-...` |
| Local, git + different cwd | `my-project  main [!?] > ./subdir \| 776fca86-...` |
| Local, no git + different cwd | `my-project > ./subdir \| 776fca86-...` |
| SSH, git | `id@oam my-project  main [!?] \| 776fca86-...` |
| Worktree (worktree row appears) | `~/repos/my-project [!?] \| 776fca86-...`<br>` ../.worktrees/my-project/my-branch` |

| Segment | Source field | Logic |
|---------|-------------|-------|
| SSH host prefix | `$SSH_CONNECTION` env var | Only shown in SSH sessions. Styled with bold + inverted + true color from the active Starship palette's `color1`. |
| Project path | `workspace.project_dir` | Git main tree: basename only. Non-git: full path with `~` home abbreviation. In a worktree: full `~`-abbreviated path of the dir the session was registered to — or of the repo's main checkout when the session was launched inside the worktree itself. |
| Branch | `git branch --show-current` | `` (U+E0A0 Powerline icon) + name. Omitted in worktree sessions, where the worktree row identifies the checkout instead. |
| Git status | `git diff`, `git ls-files` | Presence-only icons in brackets: `+` staged, `!` modified, `?` untracked. No counts. |
| Working directory | `workspace.current_dir` | Shown as `> ./relative` only when different from project dir. Suppressed in worktree sessions, where cwd is inside the worktree by definition and the worktree row already locates it. |
| Session ID | `session_id` | UUID at end, separated by ` \| `. |

**Width limit:** 90 characters. If the workspace row exceeds this, the session ID wraps to a new line. Claude Code itself never wraps — it truncates an overlong row with `…` — which is why the worktree path gets its own row rather than being appended here.

## Worktree row breakdown — active git worktree

The worktree row appears **only** when the current directory sits inside a linked worktree (one created by `git worktree add`). Main working trees render their quota and workspace rows exactly as before.

```
 ../.worktrees/my-project/my-branch
```

| Segment | Source | Logic |
|---------|--------|-------|
| Worktree icon | — | `` (U+F07B), distinct from the branch icon so the row is unambiguous. |
| Worktree path | `git rev-parse --show-toplevel` | Rendered relative to the repo's **main checkout** (`git rev-parse --git-common-dir`'s parent), so the same worktree reads identically whether the session was launched in the main tree or inside the worktree. `.`-prefixed when the worktree is nested inside the main tree (`./.claude/worktrees/agent-x`), `../` chains when it lives outside it. |
| `~` shortening | `$HOME` | A worktree under `$HOME` is shown as `~/...` when that renders shorter than the `../` chain. A worktree outside `$HOME` — including one under another user's home — always keeps the explicit relative path, because `~/...` there would name the wrong directory. |

Detection uses the filesystem, not the payload: a linked worktree has a `.git` **file**, a main tree has a `.git` **directory**, and a submodule checkout — which also carries a `.git` file — is excluded via `git rev-parse --show-superproject-working-tree`. The `worktree.*` payload fields are deliberately unused — they populate only for `--worktree` sessions, and `workspace.git_worktree` carries just a basename, not the path.

Worktree layouts seen on this fleet, all rendered by the same logic: central pool (`../.worktrees/repo/branch`), flat pool (`../.worktrees/branch`), sibling suffix dirs (`../repo-covers`), pools nested in the main tree (`./.worktrees/branch`, `./.claude/worktrees/agent-x`), and out-of-tree scratchpads (`../../../tmp/...`).

## Out-of-band JSON capture

Claude Code exposes `rate_limits.*` only to the statusline command, not to hooks or stream-json. By default, the bash script tees each Claude payload to two files:

- `/tmp/statusline-${session_id}.json` — per-session capture, race-free across concurrent sessions
- `/tmp/statusline-latest.json` — the most recent Claude payload

Set `STATUSLINE_PAYLOAD_TEE=0` for a non-Claude render. The omp footer extension does this so it cannot overwrite `/tmp/statusline-latest.json`, which shift-change's `clock-out.sh` uses to recover the active Claude session ID.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `STATUSLINE_NOW_EPOCH` | current Unix epoch | Overrides “now” for deterministic pace and countdown tests. |
| `STATUSLINE_OMP_DISABLE` | `0` | Set to `1` to disable the omp cache source and refresh entirely. |
| `STATUSLINE_OMP_CACHE` | `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/omp-usage.json` | Verbatim `omp usage --json` cache path. |
| `STATUSLINE_OMP_TTL` | `60` | Cache age in seconds before an available `omp` binary refreshes it. A readable cache is still rendered when refresh fails. |
| `STATUSLINE_OMP_TIMEOUT` | `10` | Seconds allowed for the cache refresh command. |
| `STATUSLINE_PAYLOAD_TEE` | enabled unless exactly `0` | Set to `0` to suppress both `/tmp/statusline-${session_id}.json` and `/tmp/statusline-latest.json`. |
| `STATUSLINE_SSH_PROBE_PROC` | `1` | Set to `0` to disable the parent-process SSH environment fallback used for multiplexers. |

## Deterministic test clock

The script honors `STATUSLINE_NOW_EPOCH` — when set to a Unix timestamp, all “now”-relative computations (pace, countdown, “is reset today?”) use that value instead of the system clock.

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

Claude Code's [status line feature](https://docs.anthropic.com/en/docs/claude-code/statusline) runs a configured command after each assistant message (debounced at 300ms). The command receives a JSON payload on stdin and prints a payload row plus a workspace row, with optional cache and worktree rows.

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
| `workspace.git_worktree`, `worktree.*` | string / object | **Unused.** `worktree.*` populates only for `--worktree` sessions (verified `null` in real worktree payloads on this fleet), and `workspace.git_worktree` is a basename with no path. The worktree line is derived from git instead. |
| `rate_limits.five_hour.used_percentage` | number (absent if not Max) | Uncolored 5h percentage |
| `rate_limits.five_hour.resets_at` | number (absent if not Max) | 5h reset time |
| `rate_limits.seven_day.used_percentage` | number (absent if not Max) | 7d actual percentage, colored against pace |
| `rate_limits.seven_day.resets_at` | number (absent if not Max) | 7d reset time/day + countdown + pace |
| `rate_limits.seven_day_sonnet.used_percentage` | number (undocumented; absent today) | s7d actual percentage, colored against pace when present |
| `rate_limits.seven_day_sonnet.resets_at` | number (undocumented; absent today) | s7d pace, when present |

### Performance

- **Payload parsing:** one jq invocation extracts the Claude payload fields; an enabled omp cache uses one additional jq pass for its provider limits.
- **Git caching:** git status is cached in a temp file with a 5-second TTL. On cache hit, zero git commands run.
- **Early-exit git checks:** `head -1` on git output avoids reading full diffs just to check if changes exist.
- **Buffered output:** one final `printf` call emits all output rows, avoiding pty-flush splits that would otherwise render line 1 alone for a frame.

## Tests

```sh
bash tests/run.sh
```

Runs 101 bash assertions: 51 in `test_statusline.sh` for context bands, quota color rules, pace/countdown, model/effort, SSH, and absent-field handling; 25 in `test_worktree.sh`, which builds real repos with `git worktree add` layouts; and 25 in `test_omp_usage.sh` for cached Fable/Codex rendering, field-level gap fill, cache row order, colored cache actuals, reset-less windows, and payload tee gating. Tests pin the clock via `STATUSLINE_NOW_EPOCH=1747000000` so pace and countdown are deterministic across hosts.
