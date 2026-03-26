#!/usr/bin/env bash
#
# Claude Code Status Line (Main Entry Point)
# ==========================================
# This is the script to configure in Claude Code settings.
# It handles:
#   1. Reading stdin JSON from Claude Code
#   2. Checking cache freshness
#   3. Running calculator if cache is stale
#   4. Calling the display script
#
# Configuration in ~/.claude/settings.json:
# {
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/statusline/statusline.sh"
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
CACHE_FILE="${CLAUDE_DIR}/usage_cache.json"
CALC_SCRIPT="${SCRIPT_DIR}/claude_usage_calc.py"
DISPLAY_SCRIPT="${SCRIPT_DIR}/statusline_display.sh"

# Cache freshness threshold in seconds
CACHE_MAX_AGE=20

# ============================================================================
# Functions
# ============================================================================

get_cache_age() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo 999999
        return
    fi
    
    local now cache_mtime
    now=$(date +%s)
    
    # Cross-platform stat
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    else
        cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    fi
    
    echo $(( now - cache_mtime ))
}

ensure_fresh_cache() {
    local cache_age
    cache_age=$(get_cache_age)
    
    if (( cache_age > CACHE_MAX_AGE )); then
        # Run calculator to refresh cache
        if [[ -f "$CALC_SCRIPT" ]]; then
            python3 "$CALC_SCRIPT" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Read stdin from Claude Code (this must happen first!)
    local stdin_json
    stdin_json=$(cat)
    
    # Ensure cache is fresh
    ensure_fresh_cache
    
    # Call display script, piping the stdin JSON to it
    if [[ -f "$DISPLAY_SCRIPT" ]]; then
        echo "$stdin_json" | bash "$DISPLAY_SCRIPT"
    else
        # Fallback minimal display
        local model
        model=$(echo "$stdin_json" | jq -r '.model.display_name // .model.id // "?"' 2>/dev/null || echo "?")
        echo "$model"
    fi
}

main
