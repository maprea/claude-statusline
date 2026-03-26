# Claude Code Status Line

A sober status bar for Claude Code that displays real-time usage metrics using server-side rate limit data.

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square)
![Dark Terminal Theme](https://img.shields.io/badge/Theme-Dark%20Terminal-333?style=flat-square)

## Features

| Feature | Description |
|---------|-------------|
| **Current Model** | Active Claude model (Opus, Sonnet, Haiku) |
| **Project Folder** | Current working directory name |
| **Session Tokens** | Input (↓), Output (↑), and Total (Σ) for current session |
| **5hr Window** | Progress bar + percentage + time to reset (relative and absolute) |
| **Weekly Quota** | Percentage + time to reset (relative and absolute) |
| **Context Window** | Context usage percentage |
| **Effort Level** | Thinking effort (L/M/H/⚡) |
| **Cold Start Metrics** | Shows last-known metrics when Claude Code starts before receiving new data |

## Screenshot

```
[Opus] 📁 claude-statusline │ ↓0·↑0·Σ0 │ 5h:▓▓░░░░░░  30% (3h29m→04:33) │ wk:43% (4d3h→05:00) │ ctx:15% │ H
```

## Architecture

```
Claude Code (stdin JSON with rate_limits) → statusline.sh → statusline_display.sh → [ANSI status bar]
```

Rate limit percentages (`five_hour`, `seven_day`) come directly from Claude Code's stdin JSON — authoritative server-side data, no estimation or local calculation needed.

## Installation

### Prerequisites

- **jq** — JSON processor
- **bc** — calculator (for token formatting)

```bash
# macOS
brew install jq bc

# Ubuntu/Debian
sudo apt-get install jq bc

# Fedora/RHEL
sudo dnf install jq bc
```

### Quick Install

```bash
git clone <repo-url> && cd claude-statusline
./setup.sh
```

### Manual Install

1. Copy scripts:
   ```bash
   mkdir -p ~/.claude/statusline
   cp statusline.sh statusline_display.sh ~/.claude/statusline/
   chmod +x ~/.claude/statusline/*.sh
   ```

2. Edit `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline/statusline.sh"
     }
   }
   ```

3. Restart Claude Code

## How It Works

### Project Folder
Displays the current working directory name, sourced from `cwd` in Claude Code's stdin JSON.

### Session Tokens
Comes from `context_window.total_input_tokens` and `total_output_tokens` in Claude Code's stdin JSON. Real-time and accurate.

### 5-Hour Window & Weekly Quota
Read from `rate_limits.five_hour` and `rate_limits.seven_day` in Claude Code's stdin JSON. These are server-side percentages that match exactly what the Claude web UI shows. Available after the first API response in a session.

### Context Window
Read from `context_window.used_percentage` — how much of the model's context window is in use.

### Effort Level
Read from `effort_level` in stdin JSON. Falls back to "medium" if not available.

### Cold Start Metrics
When Claude Code starts a new session, the status line automatically caches the last received rate limits and effort level to `~/.claude/statusline/.last_metrics.json`. When Claude Code hasn't received new data yet (before the first API response), the display merges the cached values into the output, so you see the previous session's metrics instead of 0%/(inactive). Once the first API response arrives with current rate limit data, that takes precedence and the cache is updated.

## Customization

### Colors

Edit `statusline_display.sh` to change the color palette:

```bash
FG_CYAN='\033[38;5;80m'
FG_BLUE='\033[38;5;75m'
FG_GREEN='\033[38;5;114m'
FG_YELLOW='\033[38;5;222m'
FG_ORANGE='\033[38;5;216m'
FG_RED='\033[38;5;174m'
```

### Progress Bar

```bash
# Width (default 8 characters)
render_progress_bar "$window_pct" 8

# Color thresholds: green <50%, yellow 50-75%, orange 75-90%, red >90%
```

## Troubleshooting

### Status line not showing
1. Accept workspace trust dialog when Claude Code prompts
2. Check permissions: `chmod +x ~/.claude/statusline/*.sh`
3. Test: `echo '{}' | ~/.claude/statusline/statusline.sh`

### 0% / (inactive) for rate limits
Before the first API response in a session, the display shows cached metrics from the last session. After Claude Code receives its first response, current rate limits appear. If you want to clear the cache, delete `~/.claude/statusline/.last_metrics.json`.

### Percentages differ slightly from web UI
Both should match exactly since they use the same server-side data. Small timing differences are possible since the status line reads the data at a slightly different moment.

## Uninstallation

```bash
./setup.sh --uninstall
```

Or manually:
```bash
rm -rf ~/.claude/statusline
# Remove statusLine from ~/.claude/settings.json
```

## Files

| File | Purpose |
|------|---------|
| `statusline.sh` | Entry point, pipes stdin to display script |
| `statusline_display.sh` | Renders ANSI-colored status bar |
| `setup.sh` | Installation/uninstallation script |

## License

MIT License — feel free to modify and share.

## Credits

Inspired by the Claude Code community tools:
- [ccusage](https://github.com/ryoppippi/ccusage)
- [ccstatusline](https://github.com/sirmalloc/ccstatusline)
- [claude-code-log](https://github.com/daaain/claude-code-log)
