#!/usr/bin/env bash
#
# Claude Code Status Line (Main Entry Point)
# ==========================================
# Reads stdin JSON from Claude Code and pipes it to the display script.
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
DISPLAY_SCRIPT="${SCRIPT_DIR}/statusline_display.sh"
CACHE_FILE="${HOME}/.claude/statusline/.last_metrics.json"

main() {
    local stdin_json
    stdin_json=$(cat)

    # Check if stdin has rate_limits data (present after first API response)
    local has_metrics
    if echo "$stdin_json" | jq -e '.rate_limits.five_hour' >/dev/null 2>&1; then
        has_metrics="yes"
    else
        has_metrics="no"
    fi

    if [[ "$has_metrics" == "yes" ]]; then
        # Save current metrics to cache
        echo "$stdin_json" > "$CACHE_FILE" 2>/dev/null || true
    elif [[ -f "$CACHE_FILE" ]]; then
        # No rate_limits yet — merge cached rate_limits/effort into current JSON
        local cached
        cached=$(cat "$CACHE_FILE" 2>/dev/null || echo '{}')
        stdin_json=$(jq -s '
            .[1] as $cached |
            .[0] |
            if (.rate_limits.five_hour == null) then
                .rate_limits = ($cached.rate_limits // {})
            else . end |
            if (.effort_level == null) then
                .effort_level = ($cached.effort_level // null)
            else . end
        ' <(echo "$stdin_json") <(echo "$cached") 2>/dev/null || echo "$stdin_json")
    fi

    if [[ -f "$DISPLAY_SCRIPT" ]]; then
        echo "$stdin_json" | bash "$DISPLAY_SCRIPT"
    else
        local model
        model=$(echo "$stdin_json" | jq -r '.model.display_name // .model.id // "?"' 2>/dev/null || echo "?")
        echo "$model"
    fi
}

main
