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

main() {
    local stdin_json
    stdin_json=$(cat)

    if [[ -f "$DISPLAY_SCRIPT" ]]; then
        echo "$stdin_json" | bash "$DISPLAY_SCRIPT"
    else
        local model
        model=$(echo "$stdin_json" | jq -r '.model.display_name // .model.id // "?"' 2>/dev/null || echo "?")
        echo "$model"
    fi
}

main
