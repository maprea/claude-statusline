#!/usr/bin/env bash
#
# Claude Code Status Line Display
# ================================
# Reads Claude Code stdin JSON to render status bar.
#
# Features:
# - Current model
# - Session tokens (input/output/total)
# - 5hr window progress bar + percentage + time to reset
# - Weekly quota percentage + time to reset
# - Context window usage percentage
# - Effort level (L/M/H/⚡)
#
# Colors: Designed for dark terminals, sober palette
#
# Usage: Configure in ~/.claude/settings.json:
# {
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/statusline_display.sh"
#   }
# }

set -euo pipefail

# ============================================================================
# Configuration & Colors (ANSI escape codes for dark terminal)
# ============================================================================

# Reset
RST='\033[0m'

# Sober dark terminal palette
DIM='\033[2m'
BOLD='\033[1m'

# Foreground colors
FG_GRAY='\033[38;5;245m'
FG_WHITE='\033[38;5;255m'
FG_CYAN='\033[38;5;80m'
FG_BLUE='\033[38;5;75m'
FG_GREEN='\033[38;5;114m'
FG_YELLOW='\033[38;5;222m'
FG_ORANGE='\033[38;5;216m'
FG_RED='\033[38;5;174m'
FG_PURPLE='\033[38;5;183m'
FG_MAGENTA='\033[38;5;176m'

# Background for progress bar
BG_GRAY='\033[48;5;238m'
BG_GREEN='\033[48;5;22m'
BG_YELLOW='\033[48;5;58m'
BG_RED='\033[48;5;52m'

# Separators
SEP="${FG_GRAY}│${RST}"
SEP_LIGHT="${DIM}·${RST}"

# ============================================================================
# Helper Functions
# ============================================================================

# Read JSON from stdin (Claude Code's input)
read_stdin_json() {
    cat
}

# Safe jq with fallback
jq_safe() {
    local json="$1"
    local query="$2"
    local default="${3:-}"
    echo "$json" | jq -r "$query // \"$default\"" 2>/dev/null || echo "$default"
}

# Format number with K/M suffix
format_tokens() {
    local n="$1"
    if [[ -z "$n" || "$n" == "null" ]]; then
        echo "0"
        return
    fi
    
    if (( n >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc)"
    elif (( n >= 1000 )); then
        printf "%.1fK" "$(echo "scale=1; $n / 1000" | bc)"
    else
        echo "$n"
    fi
}

# Get color based on percentage (for thresholds)
get_pct_color() {
    local pct="$1"
    if (( pct < 50 )); then
        echo "$FG_GREEN"
    elif (( pct < 75 )); then
        echo "$FG_YELLOW"
    elif (( pct < 90 )); then
        echo "$FG_ORANGE"
    else
        echo "$FG_RED"
    fi
}

# Get background color for progress bar
get_bar_bg() {
    local pct="$1"
    if (( pct < 50 )); then
        echo "$BG_GREEN"
    elif (( pct < 75 )); then
        echo "$BG_YELLOW"
    else
        echo "$BG_RED"
    fi
}

# Render progress bar
render_progress_bar() {
    local pct="$1"
    local width="${2:-10}"
    local label="${3:-}"
    
    # Clamp percentage
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    
    local bar_bg
    bar_bg=$(get_bar_bg "$pct")
    local pct_color
    pct_color=$(get_pct_color "$pct")
    
    # Build bar
    local bar=""
    if (( filled > 0 )); then
        bar+="${bar_bg}"
        for ((i=0; i<filled; i++)); do
            bar+="▓"
        done
        bar+="${RST}"
    fi
    if (( empty > 0 )); then
        bar+="${BG_GRAY}${FG_GRAY}"
        for ((i=0; i<empty; i++)); do
            bar+="░"
        done
        bar+="${RST}"
    fi
    
    # Add percentage
    printf "%s ${pct_color}%3d%%${RST}" "$bar" "$pct"
    
    if [[ -n "$label" ]]; then
        printf " ${FG_GRAY}%s${RST}" "$label"
    fi
}

# Format time remaining
format_time_remaining() {
    local seconds="$1"
    
    if [[ -z "$seconds" || "$seconds" == "null" || "$seconds" -le 0 ]]; then
        echo "--"
        return
    fi
    
    local hours=$(( seconds / 3600 ))
    local mins=$(( (seconds % 3600) / 60 ))
    
    if (( hours > 24 )); then
        local days=$(( hours / 24 ))
        hours=$(( hours % 24 ))
        echo "${days}d${hours}h"
    elif (( hours > 0 )); then
        printf "%dh%02dm" "$hours" "$mins"
    else
        printf "%dm" "$mins"
    fi
}

# Format absolute time
format_absolute_time() {
    local timestamp="$1"
    
    if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
        echo "--:--"
        return
    fi
    
    # Use date to format (works on both macOS and Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -r "$timestamp" "+%H:%M" 2>/dev/null || echo "--:--"
    else
        date -d "@$timestamp" "+%H:%M" 2>/dev/null || echo "--:--"
    fi
}

# ============================================================================
# Main Rendering
# ============================================================================

main() {
    # Read stdin JSON from Claude Code
    local stdin_json
    stdin_json=$(read_stdin_json)
    
    # ========================================================================
    # Extract data from Claude Code's stdin
    # ========================================================================
    
    # Model
    local model_id model_name
    model_id=$(jq_safe "$stdin_json" '.model.id' 'unknown')
    model_name=$(jq_safe "$stdin_json" '.model.display_name' '')
    
    # Use short model name
    if [[ -n "$model_name" && "$model_name" != "null" ]]; then
        model_display="$model_name"
    else
        # Extract short name from model ID (e.g., claude-opus-4-6 -> Opus)
        case "$model_id" in
            *opus*) model_display="Opus" ;;
            *sonnet*) model_display="Sonnet" ;;
            *haiku*) model_display="Haiku" ;;
            *) model_display="${model_id:-?}" ;;
        esac
    fi
    
    # Session tokens from Claude Code's context_window
    local session_input session_output session_total
    session_input=$(jq_safe "$stdin_json" '.context_window.total_input_tokens' '0')
    session_output=$(jq_safe "$stdin_json" '.context_window.total_output_tokens' '0')
    
    # Handle null/empty values
    [[ "$session_input" == "null" ]] && session_input=0
    [[ "$session_output" == "null" ]] && session_output=0
    
    session_total=$(( session_input + session_output ))
    
    # Context window usage
    local context_pct
    context_pct=$(jq_safe "$stdin_json" '.context_window.used_percentage' '0')
    [[ "$context_pct" == "null" ]] && context_pct=0
    
    # ========================================================================
    # Rate limits from Claude Code's stdin (authoritative server-side data)
    # ========================================================================

    local window_pct window_reset_ts window_active
    local weekly_pct weekly_reset_ts

    # Read directly from stdin JSON — no estimation needed
    window_pct=$(jq_safe "$stdin_json" '.rate_limits.five_hour.used_percentage' '')
    window_reset_ts=$(jq_safe "$stdin_json" '.rate_limits.five_hour.resets_at' '')
    weekly_pct=$(jq_safe "$stdin_json" '.rate_limits.seven_day.used_percentage' '')
    weekly_reset_ts=$(jq_safe "$stdin_json" '.rate_limits.seven_day.resets_at' '')

    # Get current time once for all calculations
    local now_ts
    now_ts=$(date +%s)

    # Calculate window time remaining
    local window_remaining=0
    if [[ -n "$window_reset_ts" && "$window_reset_ts" != "null" ]]; then
        window_remaining=$(( window_reset_ts - now_ts ))
        (( window_remaining < 0 )) && window_remaining=0
        window_active="true"
    else
        window_active="false"
    fi

    # Calculate weekly time remaining
    local weekly_remaining=0
    local weekly_active="false"
    if [[ -n "$weekly_reset_ts" && "$weekly_reset_ts" != "null" ]]; then
        weekly_remaining=$(( weekly_reset_ts - now_ts ))
        (( weekly_remaining < 0 )) && weekly_remaining=0
        weekly_active="true"
    fi

    # Truncate percentages to integer
    [[ -z "$window_pct" || "$window_pct" == "null" ]] && window_pct=0
    window_pct=${window_pct%%.*}
    [[ -z "$weekly_pct" || "$weekly_pct" == "null" ]] && weekly_pct=0
    weekly_pct=${weekly_pct%%.*}

    # Context window percentage (truncate to integer)
    local context_pct_int
    context_pct_int=${context_pct%%.*}

    # Effort level
    local effort_level
    effort_level=$(jq_safe "$stdin_json" '.effort_level' '')
    if [[ -z "$effort_level" || "$effort_level" == "null" ]]; then
        effort_level="medium"
    fi
    
    # ========================================================================
    # Build output line
    # ========================================================================
    
    local output=""
    
    # 1. Model + Project
    local cwd_name
    cwd_name=$(jq_safe "$stdin_json" '.cwd' '')
    if [[ -n "$cwd_name" && "$cwd_name" != "null" ]]; then
        cwd_name="${cwd_name##*/}"
    else
        cwd_name="$(basename "$PWD")"
    fi
    output+="${FG_CYAN}${BOLD}[${model_display}]${RST}"
    output+=" ${FG_GRAY}📁 ${cwd_name}${RST}"
    output+=" ${SEP} "

    # 2. Session tokens (input/output/total)
    local session_in_fmt session_out_fmt session_tot_fmt
    session_in_fmt=$(format_tokens "$session_input")
    session_out_fmt=$(format_tokens "$session_output")
    session_tot_fmt=$(format_tokens "$session_total")
    
    output+="${FG_BLUE}↓${session_in_fmt}${RST}"
    output+="${SEP_LIGHT}"
    output+="${FG_PURPLE}↑${session_out_fmt}${RST}"
    output+="${SEP_LIGHT}"
    output+="${FG_WHITE}Σ${session_tot_fmt}${RST}"
    output+=" ${SEP} "
    
    # 3. Window progress bar + time
    output+="${FG_GRAY}5h:${RST}"
    output+=$(render_progress_bar "$window_pct" 8)
    
    # Window time remaining
    local window_time_str
    window_time_str=$(format_time_remaining "$window_remaining")
    local window_abs_str
    window_abs_str=$(format_absolute_time "$window_reset_ts")
    
    if [[ "$window_active" == "true" ]]; then
        output+=" ${FG_GRAY}(${window_time_str}→${window_abs_str})${RST}"
    else
        output+=" ${DIM}(inactive)${RST}"
    fi
    output+=" ${SEP} "
    
    # 4. Weekly percentage + time
    local weekly_pct_color
    weekly_pct_color=$(get_pct_color "$weekly_pct")
    output+="${FG_GRAY}wk:${RST}${weekly_pct_color}${weekly_pct}%${RST}"

    if [[ "$weekly_active" == "true" ]]; then
        local weekly_time_str
        weekly_time_str=$(format_time_remaining "$weekly_remaining")
        local weekly_abs_str
        weekly_abs_str=$(format_absolute_time "$weekly_reset_ts")
        output+=" ${FG_GRAY}(${weekly_time_str}→${weekly_abs_str})${RST}"
    fi
    output+=" ${SEP} "

    # 5. Context window usage
    local ctx_color
    ctx_color=$(get_pct_color "$context_pct_int")
    output+="${FG_GRAY}ctx:${RST}${ctx_color}${context_pct_int}%${RST}"
    output+=" ${SEP} "

    # 6. Effort level
    local effort_short effort_color
    case "$effort_level" in
        "low")    effort_short="L";  effort_color="$FG_GRAY" ;;
        "medium") effort_short="M";  effort_color="$FG_BLUE" ;;
        "high")   effort_short="H";  effort_color="$FG_ORANGE" ;;
        "max")    effort_short="⚡"; effort_color="$FG_RED" ;;
        *)        effort_short="?";  effort_color="$FG_GRAY" ;;
    esac
    output+="${effort_color}${effort_short}${RST}"

    # Print the line
    printf '%b\n' "$output"
}

# Run main
main
