# Claude Code Status Line

A beautiful, sober status bar for Claude Code that displays comprehensive usage metrics.

![Dark Terminal Theme](https://img.shields.io/badge/Theme-Dark%20Terminal-333?style=flat-square)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square)
![Python](https://img.shields.io/badge/Python-3.8+-3776AB?style=flat-square)

## Features

| Feature | Description |
|---------|-------------|
| **Current Model** | Shows the active Claude model (Opus, Sonnet, Haiku) |
| **Session Tokens** | Input (↓), Output (↑), and Total (Σ) tokens for current session |
| **5hr Window** | Progress bar with percentage and time to reset |
| **Weekly Quota** | Percentage of weekly quota used |
| **Mode** | Current mode (⏸ plan, ⏵⏵ accept edits, ● normal) |
| **Effort Level** | Thinking effort (L/M/H/⚡) |

## Screenshot

```
Opus │ ↓12.3K·↑8.4K·Σ20.7K │ 5h:▓▓▓▓░░░░  42% (2h15m→14:30) │ wk:23% │ ⏵⏵ │ H
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Claude Code                                 │
│                          │                                       │
│                    stdin (JSON)                                  │
│                          ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                  statusline.sh                              │ │
│  │  • Reads stdin JSON from Claude Code                        │ │
│  │  • Checks cache freshness (< 20s)                          │ │
│  │  • Triggers calculator if cache is stale                    │ │
│  │  • Pipes to display script                                  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                          │                                       │
│         ┌────────────────┴────────────────┐                     │
│         ▼                                 ▼                      │
│  ┌──────────────┐              ┌─────────────────────┐          │
│  │ usage_cache  │◄─────────────│ claude_usage_calc.py│          │
│  │    .json     │              │                     │          │
│  └──────────────┘              │ • Parses JSONL logs │          │
│         │                      │ • Per-session usage │          │
│         │                      │ • Window boundaries │          │
│         │                      │ • Weekly aggregates │          │
│         ▼                      └─────────────────────┘          │
│  ┌──────────────────────┐              ▲                        │
│  │ statusline_display.sh│              │                        │
│  │                      │       ┌──────┴──────┐                 │
│  │ • Formats output     │       │ calc_daemon │                 │
│  │ • ANSI colors        │       │ (optional)  │                 │
│  │ • Progress bars      │       │ runs @15s   │                 │
│  └──────────────────────┘       └─────────────┘                 │
│              │                                                   │
│              ▼                                                   │
│        [Status Bar]                                              │
└─────────────────────────────────────────────────────────────────┘
```

## Installation

### Prerequisites

- **Python 3.8+**
- **jq** - JSON processor
- **bc** - Calculator (for formatting)

```bash
# macOS
brew install jq bc python3

# Ubuntu/Debian
sudo apt-get install jq bc python3

# Fedora/RHEL
sudo dnf install jq bc python3
```

### Quick Install

```bash
# Clone or download the files
cd /path/to/statusline

# Run setup
./setup.sh

# With background daemon (recommended for accuracy)
./setup.sh --daemon
```

### Manual Install

1. Copy files to `~/.claude/statusline/`:
   ```bash
   mkdir -p ~/.claude/statusline
   cp *.sh *.py ~/.claude/statusline/
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

## Configuration

### Status Line Settings

The status line is configured in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline/statusline.sh",
    "padding": 0
  }
}
```

### Background Daemon

For more accurate cumulative tracking, run the calculator daemon:

```bash
# Start daemon (runs every 15 seconds)
~/.claude/statusline/calc_daemon.sh start

# Check status
~/.claude/statusline/calc_daemon.sh status

# Stop daemon
~/.claude/statusline/calc_daemon.sh stop
```

#### macOS (launchd)

```bash
./setup.sh --daemon
# Creates ~/Library/LaunchAgents/com.claude.usage-calc.plist
```

#### Linux (systemd)

```bash
./setup.sh --daemon
# Creates ~/.config/systemd/user/claude-usage-calc.timer
```

## How It Works

### Per-Session Tracking

Each Claude Code terminal gets its own session with a unique UUID. The calculator parses:

```
~/.claude/projects/<project-path>/<session-uuid>.jsonl
```

Session tokens shown in the status bar come directly from Claude Code's stdin JSON (real-time, accurate).

### Window Detection (5-hour)

The 5-hour window is auto-detected by analyzing activity patterns:

1. Parse all session JSONL files
2. Group messages by timestamp
3. Detect gaps > 5 hours (new window starts)
4. Calculate remaining time to current window end

**No manual configuration needed** - windows are detected from actual usage.

### Weekly Quota

Similar to window detection:

1. Analyze past 7 days of activity
2. Sum all tokens across all sessions
3. Estimate percentage based on plan limits

### Plan Limits

Estimated limits (actual limits vary by plan and are not exposed by API):

| Plan | 5hr Window | Weekly |
|------|-----------|--------|
| Pro | ~400K tokens | ~3M tokens |
| Max5 | ~10M tokens | ~50M tokens |
| Max20 | ~40M tokens | ~200M tokens |

## Customization

### Colors

Edit `statusline_display.sh` to change the color palette:

```bash
# Current sober dark theme
FG_CYAN='\033[38;5;80m'
FG_BLUE='\033[38;5;75m'
FG_GREEN='\033[38;5;114m'
FG_YELLOW='\033[38;5;222m'
FG_ORANGE='\033[38;5;216m'
FG_RED='\033[38;5;174m'
```

### Progress Bar

Adjust bar width and thresholds:

```bash
# In statusline_display.sh
render_progress_bar "$window_pct" 8  # width=8 characters

# Threshold colors
get_pct_color() {
    if (( pct < 50 )); then  # Green below 50%
    elif (( pct < 75 )); then  # Yellow 50-75%
    elif (( pct < 90 )); then  # Orange 75-90%
    else  # Red above 90%
}
```

### Cache Refresh

Adjust how often the calculator runs:

```bash
# In calc_daemon.sh
REFRESH_INTERVAL=15  # seconds

# In statusline.sh
CACHE_MAX_AGE=20  # seconds before triggering inline calculation
```

## Troubleshooting

### Status line not showing

1. Accept workspace trust dialog when Claude Code prompts
2. Check script permissions: `chmod +x ~/.claude/statusline/*.sh`
3. Test manually: `echo '{}' | ~/.claude/statusline/statusline.sh`

### Blank or `--` values

- Normal before first API response completes
- Check if JSONL files exist: `ls ~/.claude/projects/`
- Run calculator manually: `~/.claude/statusline/calc_daemon.sh run -v`

### Context percentage differs from /context

- Status line uses `used_percentage` from stdin JSON
- `/context` command calculates at different times
- Both are accurate, just measured at different moments

### Debug mode

```bash
# Verbose calculator output
python3 ~/.claude/statusline/claude_usage_calc.py -v

# Check cache
cat ~/.claude/usage_cache.json | jq .

# Check daemon logs
tail -f ~/.claude/calc_daemon.log
```

## Uninstallation

```bash
./setup.sh --uninstall
```

Or manually:

```bash
rm -rf ~/.claude/statusline
rm -f ~/.claude/usage_cache.json
rm -f ~/.claude/calc_daemon.log
# Remove statusLine from ~/.claude/settings.json
```

## Files

| File | Purpose |
|------|---------|
| `statusline.sh` | Main entry point, configured in settings.json |
| `statusline_display.sh` | Renders the actual status bar with colors |
| `claude_usage_calc.py` | Parses JSONL files, calculates metrics |
| `calc_daemon.sh` | Background runner for the calculator |
| `setup.sh` | Installation script |
| `usage_cache.json` | Cached metrics (auto-generated) |

## License

MIT License - feel free to modify and share.

## Credits

Inspired by the Claude Code community tools:
- [ccusage](https://github.com/ryoppippi/ccusage)
- [ccstatusline](https://github.com/sirmalloc/ccstatusline)
- [claude-code-log](https://github.com/daaain/claude-code-log)
